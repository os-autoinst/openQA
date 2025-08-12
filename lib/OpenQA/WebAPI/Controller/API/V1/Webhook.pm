# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Webhook;
use Mojo::Base 'OpenQA::WebAPI::Controller::API::V1::Iso', -signatures;

use Digest::SHA 'hmac_sha256_hex';
use File::Basename;
use OpenQA::Utils;
use DBIx::Class::Timestamps 'now';
use OpenQA::Schema::Result::JobDependencies;
use OpenQA::Utils 'format_tx_error';
use OpenQA::VcsProvider;
use Mojo::Util 'secure_compare';
use Feature::Compat::Try;

my %SUPPORTED_PR_ACTIONS = (
    github => {opened => 'opened', synchronize => 'updated', closed => 'closed'},
    gitea => {review_requested => 'review_requested'},
);
my %LABEL = (
    github => 'gh:pr',
    gitea => 'gitea:pr',
);
my %UPDATE_OR_CLOSED = (
    github => {opened => 0, synchronize => 'update', closed => 'close'},
    gitea => {opened => 0, review_requested => 0},
);

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Webhook

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Webhook;

=head1 DESCRIPTION

Implements API methods to handle CI workflows based on the existing mechanism to
schedule products.

=head1 METHODS

=over 4

=item validate_signature()

Validates the webhook's signature as documented on
https://docs.github.com/en/webhooks-and-events/webhooks/securing-your-webhooks.

=back

=cut

sub validate_signature ($self) {
    my $req = $self->tx->req;
    return 0 unless my $sig = $req->headers->header('X-Hub-Signature-256');
    return 0 unless my $secret = $self->stash('webhook_validation_secret');
    my $hmac = hmac_sha256_hex($req->body, $secret);
    return secure_compare $sig, "sha256=$hmac";
}

=over 4

=item product()

Evaluates payload from a GitHub webhook. This will schedule a new product (like
OpenQA::WebAPI::Controller::API::V1::Iso::create does). It handles parameters
from GitHub's webhook payload to decid what to do exactly. The scheduled product
is always created asynchronously.

This function does not handle the "closed" or "cancel" action yet. It would make
sense to abort an existing scheduled product in this case.

This function does not handle the "push" or "synchronize" actions yet. It would make
sense to cancel and restart an existing scheduled product in this case.

=back

=cut

sub product ($self) {

    # catch the GitHub token not being configured early
    my $app = $self->app;
    my $config = $app->config;
    return $self->render(
        status => 404,
        text => 'this route is not available because no GitHub token is configured on this openQA instance'
    ) unless $config->{secrets}->{github_token};

    # validate signature
    return $self->render(status => 403, text => 'invalid signature') unless $self->validate_signature;

    # handle event header
    my $req = $self->req;
    my $event = $req->headers->header('X-Gitea-Event') // $req->headers->header('X-GitHub-Event') // '';
    my $type = $req->headers->header('X-Gitea-Event') ? 'gitea' : 'github';
    return $self->render(status => 200, text => 'pong') if $event eq 'ping';
    return $self->render(status => 404, text => 'specified event cannot be handled') unless $event eq 'pull_request';
    # validate parameters
    return undef unless $self->validate_create_parameters;
    my $json = $req->json;
    return $self->render(status => 400, text => 'JSON object payload missing') unless ref $json eq 'HASH';
    my $params = $req->params->to_hash;
    $self->_process_hook($type, $params, $json);
}

sub _process_hook ($self, $type, $params, $json) {
    my $action = $json->{action} // '';
    return $self->render(status => 404, text => 'specified action cannot be handled')
      unless my $action_str = $SUPPORTED_PR_ACTIONS{$type}->{$action};
    my $vars;
    try {
        $vars = $self->_process_payload($type, $json);
    }
    catch ($e) {
        return $self->render(status => $e->{status}, text => $e->{text});
    };

    # cancel previously scheduled jobs for this PR
    my $webhook_id = $LABEL{$type} . ":$vars->{pr_id}";
    my $scheduled_products = $self->schema->resultset('ScheduledProducts');
    my $update_or_closed = $UPDATE_OR_CLOSED{$type}->{$action};
    my $cancellation
      = $update_or_closed =~ m/update|close/ ? $scheduled_products->cancel_by_webhook_id($webhook_id, "PR $action_str") : undef;
    return $self->render(json => $cancellation) if $update_or_closed eq 'close';

    # compute parameters
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;
    return undef unless $self->validate_download_parameters(\%params);

    # set some useful defaults
    $params{BUILD} //= "$vars->{repo_name}#$vars->{sha}";
    $params{CASEDIR} //= "$vars->{clone_url}#$vars->{sha}";
    $params{_GROUP_ID} //= '0';
    $params{PRIO} //= '100';
    $params{NEEDLES_DIR} //= '%%CASEDIR%%/needles';

    # set the URL for the scenario definitions YAML file so the Minion job will download it from GitHub
    my $relative_file_path = $params{SCENARIO_DEFINITIONS_YAML_FILE} // 'scenario-definitions.yaml';
    $params{SCENARIO_DEFINITIONS_YAML_FILE} = "$vars->{raw_url}/$relative_file_path";

    # add "target URL" for the "Details" button of the CI status
    my $base_url = $self->app->config->{global}->{base_url} // $self->req->url->base;
    $params{CI_TARGET_URL} = $base_url if $base_url;

    # set GitHub parameters so the Minion job will be able to report the status back to GitHub
    $params{GITHUB_REPO} = $vars->{repo_name};
    $params{GITHUB_SHA} = $vars->{sha};
    $params{GITHUB_STATUSES_URL} = $vars->{statuses_url};
    $params{GITHUB_PR_URL} = $vars->{html_url} if $vars->{html_url};

    # create scheduled product and enqueue minion job with parameter
    my $scheduled_product = $scheduled_products->create_with_event(\%params, $self->current_user, $webhook_id);
    my $cb = sub ($ua, $tx, @) {
        if (my $err = $tx->error) {
            $scheduled_product->delete;
            return $self->render(status => 500, text => format_tx_error($err));
        }
        return $self->render(json => $scheduled_product->enqueue_minion_job(\%params));
    };
    $scheduled_product->discard_changes;    # load value of columns that have a default value
    my $vcs = "OpenQA::VcsProvider::\u$type"->new(app => $self->app);
    my $tx = $vcs->report_status_to_github($vars->{statuses_url}, {state => 'pending'}, $scheduled_product->id, $base_url, $cb);
}

sub _process_payload ($self, $type, $json) {
    my $pr = $json->{pull_request} // {};
    my %vars;
    my $head = $pr->{head} // {};
    my $repo = $head->{repo} // {};
    my @missing;
    push @missing, 'pull_request/id' unless $vars{pr_id} = $pr->{id};
    push @missing, 'pull_request/head/sha' unless $vars{sha} = $head->{sha};
    push @missing, 'pull_request/head/repo/full_name' unless $vars{repo_name} = $repo->{full_name};
    push @missing, 'pull_request/head/repo/clone_url' unless $vars{clone_url} = $repo->{clone_url};
    my $requested_reviewer;
    my $repo_html_url;
    my $repo_api_url;
    if ($type eq 'github') {
        push @missing, 'pull_request/statuses_url' unless $vars{statuses_url} = $pr->{statuses_url};
    }
    else {
        # https://src.suse.de/api/v1/repos/owner/reponame/statuses/sha
        push @missing, 'repository/url' unless $repo_api_url = $json->{repository}->{url};
        push @missing, 'repository/html_url' unless $repo_html_url = $json->{repository}->{html_url};
        push @missing, 'requested_reviewer/username' unless $requested_reviewer = $json->{requested_reviewer}->{username};
    }

    die { status => 400, text => 'missing fields: ' . join(', ', @missing)} if @missing;
    if ($type eq 'github') {
        $vars{raw_url} = "https://raw.githubusercontent.com/$vars{repo_name}/$vars{sha}";
    }
    else {
        $vars{statuses_url} = "$repo_api_url/statuses/$vars{sha}";
        my $review_user = 'qam-openqa'; # TODO configure
        unless ($requested_reviewer eq $review_user) {
            return $self->render(json => {message => "Nothing to do for reviewer $requested_reviewer"});
        }
        $vars{raw_url} = "$repo_html_url/raw/branch/$vars{sha}";
    }
    $vars{html_url} = $pr->{html_url};
    return \%vars;
}

1;
