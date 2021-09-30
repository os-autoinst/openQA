# Copyright 2015-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller';

use File::Basename;
use OpenQA::Utils;
use DBIx::Class::Timestamps 'now';
use OpenQA::Schema::Result::JobDependencies;

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
    my @mandatory_parameter = qw(DISTRI VERSION FLAVOR ARCH);

    # validate parameter
    if (defined $scheduled_product_clone_id) {
        $validation->required('scheduled_product_clone_id')->num();
        if ($validation->has_error) {
            return $self->render(text => 'Specified scheduled_product_id is invalid.', status => 400);
        }
    }
    else {
        $validation->required($_) for (@mandatory_parameter);
        if ($validation->has_error) {
            my $error = "Error: missing parameters:";
            for my $k (@mandatory_parameter) {
                $log->debug(@{$validation->error($k)}) if $validation->has_error($k);
                $error .= ' ' . $k if $validation->has_error($k);
            }
            return $self->render(text => $error, status => 400);
        }
    }

    my %params;
    if (defined $scheduled_product_clone_id) {
        # clone params from previous scheduled product
        my $previously_scheduled_product = $scheduled_products->find($scheduled_product_clone_id);
        if (!$previously_scheduled_product) {
            return $self->render(text => 'Scheduled product to clone settings from not found.', status => 404);
        }
        my $settings_to_clone = $previously_scheduled_product->settings // {};
        for my $required_param (@mandatory_parameter) {
            if (!$settings_to_clone->{$required_param}) {
                return $self->render(
                    text => "Scheduled product to clone settings from misses $required_param.",
                    status => 404
                );
            }
        }
        %params = %$settings_to_clone;
    }
    else {
        # job_create expects upper case keys
        my %up_params = map { uc $_ => $params->{$_} } keys %$params;
        # restore URL encoded /
        %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;
    }

    my @check = check_download_passlist(\%params, $self->app->config->{global}->{download_domains});
    if (@check) {
        my ($status, $param, $url, $host) = @check;
        $log->debug("$param - $url");
        if ($status == 2) {
            return $self->render(
                text => "Asset download requested but no domains passlisted! Set download_domains.",
                status => 403
            );
        }
        else {
            return $self->render(text => "Asset download requested from non-passlisted host $host.", status => 403);
        }
    }

    # add entry to ScheduledProducts table and log event
    my $scheduled_product = $scheduled_products->create(
        {
            distri => $params{DISTRI} // '',
            version => $params{VERSION} // '',
            flavor => $params{FLAVOR} // '',
            arch => $params{ARCH} // '',
            build => $params{BUILD} // '',
            iso => $params{ISO} // '',
            settings => \%params,
            user_id => $self->current_user->id,
        });
    my $scheduled_product_id = $scheduled_product->id;
    $self->emit_event(openqa_iso_create => {scheduled_product_id => $scheduled_product_id});

    # only spwan Minion job and return IDs if async flag has been passed
    if ($async) {
        my %minion_job_args = (
            scheduled_product_id => $scheduled_product_id,
            scheduling_params => \%params,
        );
        my %gru_options = (
            priority => 10,
            ttl => 10 * 60,
        );
        my $ids = $self->gru->enqueue(schedule_iso => \%minion_job_args, \%gru_options);
        my $gru_task_id = $ids->{gru_id};
        my $minion_job_id = $ids->{minion_id};
        $scheduled_product->update(
            {
                gru_task_id => $gru_task_id,
                minion_job_id => $minion_job_id,
            });
        return $self->render(
            json => {
                scheduled_product_id => $scheduled_product_id,
                gru_task_id => $gru_task_id,
                minion_job_id => $minion_job_id,
            },
        );
    }

    # schedule jobs synchronously (hopefully within the timeout)
    my $scheduled_jobs = $scheduled_product->schedule_iso(\%params);
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
    my $subquery = $schema->resultset("JobSettings")->query_for_settings({ISO => $iso});
    my @jobs
      = $schema->resultset("Jobs")->search({'me.id' => {-in => $subquery->get_column('job_id')->as_query}})->all;

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
