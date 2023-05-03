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

my %SUPPORTED_PR_ACTIONS = (opened => 1, synchronize => 1);

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
    my $event = $req->headers->header('X-GitHub-Event') // '';
    return $self->render(status => 200, text => 'pong') if $event eq 'ping';
    return $self->render(status => 404, text => 'specified event cannot be handled') unless $event eq 'pull_request';

    # validate parameters
    return undef unless $self->validate_create_parameters;
    my $json = $req->json;
    return $self->render(status => 400, text => 'JSON object payload missing') unless ref $json eq 'HASH';
    my $action = $json->{action} // '';
    return $self->render(status => 404, text => 'specified action cannot be handled')
      unless $SUPPORTED_PR_ACTIONS{$action};
    my $pr = $json->{pull_request} // {};
    my $head = $pr->{head} // {};
    my $sha = $head->{sha};
    my $repo = $head->{repo} // {};
    my $repo_name = $repo->{full_name};
    my $clone_url = $repo->{clone_url};
    my $statuses_url = $pr->{statuses_url};
    my $html_url = $pr->{html_url};
    return $self->render(
        status => 400,
        text => '"pull_request" lacks "statuses_url", "head/sha" or "head/repo/full_name" or "head/repo/clone_url"'
    ) unless $sha && $repo_name && $clone_url && $statuses_url;

    # compute parameters
    my $params = $req->params->to_hash;
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;
    return undef unless $self->validate_download_parameters(\%params);

    # set some useful defaults
    $params{BUILD} //= "$repo_name#$sha";
    $params{CASEDIR} //= "$clone_url#$sha";
    $params{_GROUP_ID} //= '0';
    $params{PRIO} //= '100';
    $params{NEEDLES_DIR} //= '%%CASEDIR%%/needles';

    # set the URL for the scenario definitions YAML file so the Minion job will download it from GitHub
    my $relative_file_path = $params{SCENARIO_DEFINITIONS_YAML_FILE} // 'scenario-definitions.yaml';
    $params{SCENARIO_DEFINITIONS_YAML_FILE} = "https://raw.githubusercontent.com/$repo_name/$sha/$relative_file_path";

    # add "target URL" for the "Details" button of the CI status
    my $base_url = $config->{global}->{base_url} // $req->url->base;
    $params{CI_TARGET_URL} = $base_url if $base_url;

    # set GitHub parameters so the Minion job will be able to report the status back to GitHub
    $params{GITHUB_REPO} = $repo_name;
    $params{GITHUB_SHA} = $sha;
    $params{GITHUB_STATUSES_URL} = $statuses_url;
    $params{GITHUB_PR_URL} = $html_url if $html_url;

    # create scheduled product and enqueue minion job with parameter
    my $scheduled_products = $self->schema->resultset('ScheduledProducts');
    my $scheduled_product = $scheduled_products->create_with_event(\%params, $self->current_user);
    my $vcs = OpenQA::VcsProvider->new(app => $app);
    my $cb = sub ($ua, $tx, @) {
        if (my $err = $tx->error) {
            $scheduled_product->delete;
            return $self->render(status => 500, text => format_tx_error($err));
        }
        return $self->render(json => $scheduled_product->enqueue_minion_job(\%params));
    };
    $scheduled_product->discard_changes;    # load value of columns that have a default value
    my $tx = $vcs->report_status_to_github($statuses_url, {state => 'pending'}, $scheduled_product->id, $base_url, $cb);
}

1;
