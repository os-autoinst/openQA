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
use OpenQA::VcsHook;
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
    my $action = $json->{action} // '';
    return $self->render(status => 404, text => 'specified action cannot be handled')
      unless my $action_str = $SUPPORTED_PR_ACTIONS{$type}->{$action};

    my $hook = "OpenQA::VcsHook::\u$type"->new();
    my $vars;
    try {
        $vars = $hook->process_payload($type, $json);
    }
    catch ($e) {
        return $self->render(status => $e->{status}, text => $e->{text});
    };

    my $update_or_closed = $UPDATE_OR_CLOSED{$type}->{$action};
    my $cancelled = $update_or_closed =~ m/update|close/;
    my $closed = $update_or_closed eq 'close';
    my $webhook_id = $LABEL{$type} . ":$vars->{pr_id}";

    # cancel previously scheduled jobs for this PR
    my $scheduled_products = $self->schema->resultset('ScheduledProducts');
    my $cancellation = $cancelled ? $scheduled_products->cancel_by_webhook_id($webhook_id, "PR $action") : undef;
    return $self->render(json => $cancellation) if $closed;

    my $params = $req->params->to_hash;
    $params = $hook->process_query_params($req->params->to_hash);

    try {
        $self->validate_download_parameters($params, 0);
    }
    catch ($e) {
        return $self->render(%$e);
    };
    my $base_url = $self->app->config->{global}->{base_url} // $self->req->url->base;
    $hook->schedule_product_params($vars, $params, $base_url);
    my $scheduled_product = $self->_schedule_product($vars, $params, $webhook_id);
    my $cb = sub ($ua, $tx, @) {
        if (my $err = $tx->error) {
            $scheduled_product->delete;
            return $self->render(status => 500, text => format_tx_error($err));
        }
        return $self->render(json => $scheduled_product->enqueue_minion_job($params));
    };
    my $vcs = "OpenQA::VcsProvider::\u$type"->new(app => $self->app);
    #    my $base_url = $self->app->config->{global}->{base_url} // $self->req->url->base;
    my $tx
      = $vcs->report_status_to_github($vars->{statuses_url}, {state => 'pending'}, $scheduled_product->id, $base_url,
        $cb);
}

sub _schedule_product ($self, $vars, $params, $webhook_id) {
    # create scheduled product and enqueue minion job with parameter
    my $scheduled_products = $self->schema->resultset('ScheduledProducts');
    my $scheduled_product = $scheduled_products->create_with_event($params, $self->current_user, $webhook_id);
    $scheduled_product->discard_changes;    # load value of columns that have a default value
    return $scheduled_product;
}

1;
