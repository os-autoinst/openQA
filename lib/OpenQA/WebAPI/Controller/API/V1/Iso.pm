# Copyright 2015-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use File::Basename;
use OpenQA::Utils;
use DBIx::Class::Timestamps 'now';
use OpenQA::Schema::Result::JobDependencies;

use constant MANDATORY_PARAMETERS => qw(DISTRI VERSION FLAVOR ARCH);

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Iso

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Iso;

=head1 DESCRIPTION

Implements API methods to handle job creation, cancellation and removal based on ISOs, ie,
schedule jobs for a given ISO, or cancel jobs for a given ISO.

=head1 METHODS

=over 4

=item show_scheduled_product()

Returns (status) information and jobs for a previously scheduled product via create().

=back

=cut

sub show_scheduled_product {
    my ($self) = @_;

    my $scheduled_product_id = $self->param('scheduled_product_id');
    my $scheduled_products = $self->app->schema->resultset('ScheduledProducts');
    my $scheduled_product = $scheduled_products->find($scheduled_product_id);
    if (!$scheduled_product) {
        return $self->render(
            json => {error => 'Scheduled product does not exist.'},
            status => 404,
        );
    }

    my @args = (include_job_ids => $self->param('include_job_ids'));

    $self->render(json => $scheduled_product->to_hash(@args));
}

=over 4

=item job_statistics()

Returns job statistics about the most recent scheduled products for each ARCH
matching the specified DISTRI, VERSION and FLAVOR. Only scheduled products that
are cancelling/cancelled are not considered.

This allows to determine whether all jobs that have been scheduled for a
certain purpose are done and whether the jobs have passed. If jobs have been
cloned/restarted then only the state/result of the latest job is taken into
account.

The statistics are returned as nested JSON object with one key per present state
on outer level and one key per present result on inner level:

{
  done => {
    failed =>     {job_ids => [5057], scheduled_product_ids => [330]},
    incomplete => {job_ids => [5056], scheduled_product_ids => [330]},
  }
}

One can check for the existence of keys in the returned JSON object to check
whether certain states/results are present. The concrete job IDs and scheduled
product IDs for each combination are mainly returned for easier retracing but
could also be used to generate a more detailed report.

=back

=cut

sub job_statistics ($self) {
    my $validation = $self->validation;
    my @param_keys = (qw(distri version flavor));
    $validation->required($_) for @param_keys;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;
    my @params = map { $validation->param($_) } @param_keys;
    my $scheduled_products = $self->app->schema->resultset('ScheduledProducts');
    $self->render(json => $scheduled_products->job_statistics(@params));
}

sub validate_create_parameters ($self) {
    my $validation = $self->validation;
    $validation->required($_) for (MANDATORY_PARAMETERS);
    return 1 unless $validation->has_error;

    my $error = 'Error: missing parameters:';
    my $log = $self->log;
    for my $k (MANDATORY_PARAMETERS) {
        $log->debug(@{$validation->error($k)}) if $validation->has_error($k);
        $error .= ' ' . $k if $validation->has_error($k);
    }
    $self->render(text => $error, status => 400);
    return 0;
}

sub validate_download_parameters ($self, $params, $render = 1) {
    my @check = check_download_passlist($params, $self->app->config->{global}->{download_domains});
    return 1 unless @check;

    my ($status, $param, $url, $host) = @check;
    $self->log->debug("$param - $url");
    my $error
      = $status == 2
      ? 'Asset download requested but no domains passlisted! Set download_domains.'
      : "Asset download requested from non-passlisted host $host.";
    die {text => $error, status => 403} unless $render;
    $self->render(text => $error, status => 403);
    return 0;
}

=over 4

=item create()

Schedule jobs for assets matching the required settings DISTRI, VERSION, FLAVOR and ARCH
passed to the method as arguments. Returns a JSON block containing the number of jobs
created, their job ids and the information for jobs that could not be scheduled.

=back

=cut

sub create {
    my ($self) = @_;

    my $params = $self->req->params->to_hash;
    my $async = delete $params->{async};    # whether to run the operation as a Minion job
    my $scheduled_product_clone_id
      = delete $params->{scheduled_product_clone_id};    # ID of a previous product to clone settings from
    my $log = $self->app->log;
    my $validation = $self->validation;
    my $scheduled_products = $self->schema->resultset('ScheduledProducts');

    # validate parameter
    if (defined $scheduled_product_clone_id) {
        $validation->required('scheduled_product_clone_id')->num();
        if ($validation->has_error) {
            return $self->render(text => 'Specified scheduled_product_id is invalid.', status => 400);
        }
    }
    else {
        return undef unless $self->validate_create_parameters;
    }

    # add parameters from the product to be cloned to the %params for the new scheduled product
    my %params;
    if (defined $scheduled_product_clone_id) {
        # add clone params from previous scheduled product
        my $previously_scheduled_product = $scheduled_products->find($scheduled_product_clone_id);
        if (!$previously_scheduled_product) {
            return $self->render(text => 'Scheduled product to clone settings from not found.', status => 404);
        }
        my $settings_to_clone = $previously_scheduled_product->settings // {};
        for my $required_param (MANDATORY_PARAMETERS) {
            if (!defined $settings_to_clone->{$required_param}) {
                return $self->render(
                    text => "Scheduled product to clone settings from misses $required_param.",
                    status => 404
                );
            }
        }
        %params = %$settings_to_clone;

        # remove parameters from product to be cloned that would conflict with the new arguments
        if ($params->{TEST}) {    # TEST conflicts with _DEPRIORITIZEBUILD and _OBSOLETE
            delete $params{$_} for qw(_DEPRIORITIZEBUILD _OBSOLETE);
        }
    }

    # add user-specified $params to %params for the new scheduled product and validate download parameters
    # note: keys are converted to upper-case, URL-encoded slashes are restored
    $params{uc $_} = ($params->{$_} =~ s@%2F@/@gr) for keys %$params;
    return undef unless $self->validate_download_parameters(\%params);

    # add entry to ScheduledProducts table and log event
    my $scheduled_product = $scheduled_products->create_with_event(\%params, $self->current_user);
    my $scheduled_product_id = $scheduled_product->id;

    # only spawn Minion job and return IDs if async flag has been passed
    return $self->render(json => $scheduled_product->enqueue_minion_job(\%params)) if $async;

    # schedule jobs synchronously (hopefully within the timeout)
    my $scheduled_jobs = $scheduled_product->schedule_iso(\%params, undef);
    my $error = $scheduled_jobs->{error};
    return $self->render(
        json => {
            scheduled_product_id => $scheduled_product_id,
            error => $error,
            count => 0,
            ids => [],
            failed => {},
        },
        status => $scheduled_jobs->{error_code},
    ) if $error;

    my $successful_job_ids = $scheduled_jobs->{successful_job_ids};
    my $failed_job_info = $scheduled_jobs->{failed_job_info};
    my $created_job_count = scalar(@$successful_job_ids);

    my $debug_message = "Created $created_job_count jobs";
    if (my $failed_job_count = scalar(@$failed_job_info)) {
        $debug_message .= " but failed to create $failed_job_count jobs";
    }
    $log->debug($debug_message);

    $self->render(
        json => {
            scheduled_product_id => $scheduled_product_id,
            count => $created_job_count,
            ids => $successful_job_ids,
            failed => $failed_job_info,
        });
}

=over 4

=item destroy()

Delete jobs whose ISO setting match a particular ISO argument passed to the method. Return a
JSON block containing the number of jobs deleted.

=back

=cut

sub destroy {
    my $self = shift;
    my $iso = $self->stash('name');
    $self->emit_event('openqa_iso_delete', {iso => $iso});

    my $schema = $self->schema;
    my $subquery = $schema->resultset('JobSettings')->query_for_settings({ISO => $iso});
    my @jobs
      = $schema->resultset('Jobs')->search({'me.id' => {-in => $subquery->get_column('job_id')->as_query}})->all;

    for my $job (@jobs) {
        $self->emit_event('openqa_job_delete', {id => $job->id});
        $job->delete;
    }
    $self->render(json => {count => scalar(@jobs)});
}

=over 4

=item cancel()

Cancel jobs whose ISO setting match a particular ISO argument passed to the method.
Return number of cancelled jobs within a JSON block.

=back

=cut

sub cancel {
    my $self = shift;
    my $iso = $self->stash('name');
    $self->emit_event('openqa_iso_cancel', {iso => $iso});

    my $res = $self->schema->resultset('Jobs')->cancel_by_settings({ISO => $iso}, 0);
    $self->render(json => {result => $res});
}

1;
