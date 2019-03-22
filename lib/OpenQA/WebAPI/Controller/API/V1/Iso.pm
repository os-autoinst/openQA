# Copyright (C) 2015-2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

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
    my $scheduled_products   = $self->app->schema->resultset('ScheduledProducts');
    my $scheduled_product    = $scheduled_products->find($scheduled_product_id);
    if (!$scheduled_product) {
        return $self->render(
            json   => {error => 'Scheduled product does not exist.'},
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

    my $log        = $self->app->log;
    my $validation = $self->validation;
    $validation->required('DISTRI');
    $validation->required('VERSION');
    $validation->required('FLAVOR');
    $validation->required('ARCH');
    if ($validation->has_error) {
        my $error = "Error: missing parameters:";
        for my $k (qw(DISTRI VERSION FLAVOR ARCH)) {
            $log->debug(@{$validation->error($k)}) if $validation->has_error($k);
            $error .= ' ' . $k if $validation->has_error($k);
        }
        $self->res->message($error);
        return $self->rendered(400);
    }

    my $params = $self->req->params->to_hash;
    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    # restore URL encoded /
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;

    my @check = check_download_whitelist(\%params, $self->app->config->{global}->{download_domains});
    if (@check) {
        my ($status, $param, $url, $host) = @check;
        if ($status == 2) {
            my $error = "Asset download requested but no domains whitelisted! Set download_domains";
            $log->debug("$param - $url");
            $self->res->message($error);
            return $self->rendered(403);
        }
        else {
            my $error = "Asset download requested from non-whitelisted host $host";
            $log->debug("$param - $url");
            $self->res->message($error);
            return $self->rendered(403);
        }
    }

    # add entry to ScheduledProducts table
    my $scheduled_products = $self->schema->resultset('ScheduledProducts');
    my $scheduled_product  = $scheduled_products->create(
        {
            distri  => $params{DISTRI}  // '',
            version => $params{VERSION} // '',
            flavor  => $params{FLAVOR}  // '',
            arch    => $params{ARCH}    // '',
            build   => $params{BUILD}   // '',
            iso     => $params{ISO}     // '',
            settings => \%params,
            user_id  => $self->current_user->id,
        });
    my $scheduled_product_id = $scheduled_product->id;

    # only spwan Minion job and return IDs if async flag has been passed
    if ($self->param('async')) {
        my %minion_job_args = (
            scheduled_product_id => $scheduled_product_id,
            scheduling_params    => \%params,
        );
        my %gru_options = (
            priority => 10,
            ttl      => 10 * 60,
        );
        my $ids           = $self->gru->enqueue(schedule_iso => \%minion_job_args, \%gru_options);
        my $gru_task_id   = $ids->{gru_id};
        my $minion_job_id = $ids->{minion_id};
        $scheduled_product->update(
            {
                gru_task_id   => $gru_task_id,
                minion_job_id => $minion_job_id,
            });
        return $self->render(
            json => {
                scheduled_product_id => $scheduled_product_id,
                gru_task_id          => $gru_task_id,
                minion_job_id        => $minion_job_id,
            },
        );
    }

    # schedule jobs synchronously (hopefully within the timeout)
    my $scheduled_jobs = $scheduled_product->schedule_iso(\%params);
    my $error          = $scheduled_jobs->{error};
    return $self->render(
        json => {
            scheduled_product_id => $scheduled_product_id,
            error                => $error,
            count                => 0,
            ids                  => [],
            failed               => {},
        },
        status => 400,
    ) if $error;

    my $successful_job_ids = $scheduled_jobs->{successful_job_ids};
    my $failed_job_info    = $scheduled_jobs->{failed_job_info};
    my $created_job_count  = scalar(@$successful_job_ids);

    my $debug_message = "Created $created_job_count jobs";
    if (my $failed_job_count = scalar(@$failed_job_info)) {
        $debug_message .= " but failed to create $failed_job_count jobs";
    }
    $log->debug($debug_message);

    $self->render(
        json => {
            scheduled_product_id => $scheduled_product_id,
            count                => $created_job_count,
            ids                  => $successful_job_ids,
            failed               => $failed_job_info,
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
    my $iso  = $self->stash('name');
    $self->emit_event('openqa_iso_delete', {iso => $iso});

    my $schema   = $self->schema;
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
    my $iso  = $self->stash('name');
    $self->emit_event('openqa_iso_cancel', {iso => $iso});

    my $res = $self->schema->resultset('Jobs')->cancel_by_settings({ISO => $iso}, 0);
    $self->render(json => {result => $res});
}

1;
# vim: set sw=4 et:
