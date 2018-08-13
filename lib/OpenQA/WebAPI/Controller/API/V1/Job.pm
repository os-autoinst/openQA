# Copyright (C) 2015-2018 SUSE Linux GmbH
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

package OpenQA::WebAPI::Controller::API::V1::Job;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::IPC;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Utils 'find_job';
use Try::Tiny;
use DBIx::Class::Timestamps 'now';
use Mojo::Asset::Memory;
use Mojo::File 'path';

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Job

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Job;

=head1 DESCRIPTION

Implements API methods to access jobs.

=head1 METHODS

=over 4

=item list()

List jobs in the system, including related information for each job such as the assets
associated, assigned worker id, children and parents, job id, group id, name, priority,
result, settings, state and times of startup and finish of the job.

=back

=cut

sub list {
    my $self = shift;

    my %args;
    my @args = qw(build iso distri version flavor maxage scope group
      groupid limit page before after arch hdd_1 test machine worker_class);
    for my $arg (@args) {
        next unless defined(my $value = $self->param($arg));
        $args{$arg} = $value;
    }
    # For these, we accept a single value, a single instance of the arg
    # with a comma-separated list of values, or multiple instances of the
    # arg. In all cases we're going to convert to an array ref of values:
    # we could let query_jobs do the string splitting for us, but this is
    # clearer.
    for my $arg (qw(state ids result)) {
        next unless defined $self->param($arg);
        if (index($self->param($arg), ',') != -1) {
            $args{$arg} = [split(',', $self->param($arg))];
        }
        else {
            $args{$arg} = $self->every_param($arg);
        }
    }

    my $rs = $self->db->resultset('Jobs')->complex_query(%args);
    my @jobarray;
    if (defined $self->param('latest')) {
        @jobarray = $rs->latest_jobs;
    }
    else {
        @jobarray = $rs->all;
    }
    my %jobs = map { $_->id => $_ } @jobarray;

    # we can't prefetch too much at once as the resulting JOIN will kill our performance horribly
    # (not so much the JOIN itself, but parsing the result containing duplicated information)
    # so we fetch some fields in a second step

    # fetch job assets
    for my $job (values %jobs) {
        $job->{_assets} = [];
    }
    my $jas = $self->db->resultset('JobsAssets')->search({job_id => {in => [keys %jobs]}}, {prefetch => ['asset']});
    while (my $ja = $jas->next) {
        my $job = $jobs{$ja->job_id};
        push(@{$job->{_assets}}, $ja->asset);
    }

    # prefetch groups
    my %groups;
    for my $job (values %jobs) {
        next unless $job->group_id;
        $groups{$job->group_id} ||= $job->group;
        $job->group($groups{$job->group_id});
    }

    my $modules = $self->db->resultset('JobModules')->search({job_id => {in => [keys %jobs]}}, {order_by => 'id'});
    while (my $m = $modules->next) {
        my $job = $jobs{$m->job_id};
        $job->{_modules} ||= [];
        push(@{$job->{_modules}}, $m);
    }

    my @results;
    for my $id (sort keys %jobs) {
        my $job = $jobs{$id};
        my $jobhash = $job->to_hash(assets => 1, deps => 1);
        $jobhash->{modules} = [];
        for my $module (@{$job->{_modules}}) {
            my $modulehash = {
                name     => $module->name,
                category => $module->category,
                result   => $module->result,
                flags    => []};
            for my $flag (qw(important fatal milestone)) {
                if ($module->get_column($flag)) {
                    push(@{$modulehash->{flags}}, $flag);
                }
            }
            push(@{$jobhash->{modules}}, $modulehash);
        }
        push @results, $jobhash;
    }
    $self->render(json => {jobs => \@results});
}

=over 4

=item overview()

Returns the latest jobs matching the specified arch, build, distri, version, flavor and groupid.
So this works in the same way as the test results overview in the GUI.

=back

=cut

sub overview {
    my $self = shift;
    my ($search_args, $groups) = OpenQA::Utils::compose_job_overview_search_args($self);
    my @jobs = map { {id => $_->id, name => $_->name} }
      $self->db->resultset('Jobs')->complex_query(%$search_args)->latest_jobs;
    $self->render(json => \@jobs);
}

=over 4

=item create()

Creates a job given a list of settings passed as parameters. TEST setting/parameter
is mandatory and should be the name of the test.

=back

=cut

sub create {
    my $self   = shift;
    my $params = $self->req->params->to_hash;

    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    # restore URL encoded /
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;
    if (!$params{TEST}) {
        return $self->render(json => {error => 'TEST field mandatory'}, status => 400);
    }

    my $json = {};
    my $status;
    try {
        my $job = $self->db->resultset('Jobs')->create_from_settings(\%params);
        $self->emit_event('openqa_job_create', {id => $job->id, %params});
        $json->{id} = $job->id;

        # enqueue gru job
        $self->gru->enqueue(limit_assets => [] => {priority => 10});
    }
    catch {
        $status = 400;
        $json->{error} = "$_";
    };

    $self->render(json => $json, status => $status);
}

=over 4

=item show()

Shows details for a specific job, such as the assets associated, assigned worker id,
children and parents, job id, group id, name, priority, result, settings, state and times
of startup and finish of the job.

=back

=cut

sub show {
    my $self    = shift;
    my $job_id  = int($self->stash('jobid'));
    my $details = $self->stash('details') || 0;
    my $job     = $self->db->resultset("Jobs")->search({'me.id' => $job_id}, {prefetch => 'settings'})->first;
    if ($job) {
        $self->render(json => {job => $job->to_hash(assets => 1, deps => 1, details => $details)});
    }
    else {
        $self->reply->not_found;
    }
}

=over 4

=item destroy()

Deletes a job from the system.

=back

=cut

sub destroy {
    my $self = shift;

    my $job = find_job($self, $self->stash('jobid')) or return;
    $self->emit_event('openqa_job_delete', {id => $job->id});
    $job->delete;
    $self->render(json => {result => 1});
}

=over 4

=item prio()

Sets priority for a given job.

=back

=cut

sub prio {
    my ($self) = @_;
    my $job = find_job($self, $self->stash('jobid')) or return;
    my $res = $job->set_prio($self->param('prio'));

    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
    $self->render(json => {result => \$res});
}

=over 4

=item result()

Updates result of a job in the system. Replaced in favor of done.

=back

=cut

sub result {
    my ($self) = @_;
    my $job    = find_job($self, $self->stash('jobid')) or return;
    my $result = $self->param('result');
    my $ipc    = OpenQA::IPC->ipc;

    my $res = $job->update({result => $result});
    $self->emit_event('openqa_job_update_result', {id => $job->id, result => $result}) if ($res);
    # See comment in prio
    $self->render(json => {result => \$res});
}

=over 4

=item update_status()

Updates status of a job. Requires a new status, the id of the job and of the
worker assigned to the job. In order to update the status, the submitted worker
id must match the id of the worker assigned to the job identified by the job id.

=back

=cut

# this is the general worker update call
sub update_status {
    my ($self) = @_;

    if (!$self->req->json) {
        $self->render(json => {error => 'No status information provided'}, status => 400);
        return;
    }
    my $status = $self->req->json->{status};

    my $job = find_job($self, $self->stash('jobid'));
    if (!$job) {
        my $err = 'Got status update for non-existing job: ' . $self->stash('jobid');
        OpenQA::Utils::log_info($err);
        $self->render(json => {error => $err}, status => 400);
        return;
    }

    if (!exists $status->{worker_id}) {
        my $err = 'Got status update for job ' . $self->stash('jobid') . ' but does not contain a worker id!';
        OpenQA::Utils::log_info($err);
        $self->render(json => {error => $err}, status => 400);
        return;
    }

    if (!$job->worker || $job->worker->id != $status->{worker_id}) {
        my $err
          = 'Got status update for job '
          . $self->stash('jobid')
          . ' that does not belong to Worker '
          . $status->{worker_id};
        OpenQA::Utils::log_info($err);
        $self->render(json => {error => $err}, status => 400);
        return;
    }

    my $ret = $job->update_status($status);
    if (!$ret || $ret->{error} || $ret->{error_status}) {
        $ret = {} unless $ret;
        $ret->{error}        //= 'Unable to update status';
        $ret->{error_status} //= 400;
        $self->render(json => {error => $ret->{error}}, status => $ret->{error_status});
        return;
    }
    $self->render(json => $ret);
}

=over 4

=item update()

Updates the settings of a job with information specified in a passed JSON argument.
Columns group_id and priority cannot be set.

=back

=cut

sub update {
    my ($self) = @_;

    my $job = find_job($self, $self->stash('jobid')) or return;
    my $json = $self->req->json;
    return $self->render(json => {error => 'No updates provided (must be provided as JSON)'}, status => 400)
      unless $json;
    my $settings = delete $json->{settings};

    # validate specified columns (print error if at least one specified column does not exist)
    my @allowed_cols = qw(group_id priority);
    for my $key (keys %$json) {
        if (!grep $_ eq $key, @allowed_cols) {
            return $self->render(json => {error => "Column $key can not be set"}, status => 400);
        }
    }

    # validate specified group
    my $group_id = $json->{group_id};
    if (defined($group_id) && !$self->db->resultset('JobGroups')->find(int($group_id))) {
        return $self->render(json => {error => 'Group does not exist'}, status => 404);
    }

    # some settings are stored directly in job table and hence must be updated there
    my @setting_cols = qw(TEST DISTRI VERSION FLAVOR ARCH BUILD MACHINE);
    if ($settings) {
        for my $setting_col (@setting_cols) {
            $json->{$setting_col} = delete $settings->{$setting_col} // '';
        }
    }

    $job->update($json);

    if ($settings) {
        # update settings stored in extra job settings table
        my @settings_keys = keys %$settings;
        for my $key (@settings_keys) {
            $job->set_property($key, $settings->{$key});
        }
        # ensure old entries are removed
        $self->db->resultset('JobSettings')->search({job_id => $job->id, key => {-not_in => \@settings_keys}})->delete;
    }

    $self->render(json => {job_id => $job->id});
}

=over 4

=item create_artefact()

Used by the worker to upload files to the test.

=back

=cut

sub create_artefact {
    my ($self) = @_;

    my $jobid = int($self->stash('jobid'));
    my $job = find_job($self, $jobid);
    if (!$job) {
        OpenQA::Utils::log_info('Got artefact for non-existing job: ' . $jobid);
        return;
    }
    if (!$job->worker) {
        OpenQA::Utils::log_info(
            'Got artefact for job with no worker assigned (maybe running job already considered dead): ' . $jobid);
        $self->render(json => {error => 'No worker assigned'}, status => 404);
        return;
    }
    # mark the worker as alive
    $job->worker->seen;

    if ($self->param('image')) {
        $job->store_image($self->param('file'), $self->param('md5'), $self->param('thumb') // 0);
        $self->render(text => "OK");
        return;
    }
    elsif ($self->param('extra_test')) {
        return $self->render(text => "OK")
          if $job->parse_extra_tests($self->param('file'), $self->param('type'), $self->param('script'));
        return $self->render(text => "FAILED");
    }
    elsif ($self->param('asset')) {
        $self->render_later;    # XXX: Not really needed, but in case of upstream changes
        my @ioloop_evs = qw(events);
        my @evs        = @{Mojo::IOLoop->singleton}{@ioloop_evs};

        # See: https://mojolicious.org/perldoc/Mojolicious/Guides/FAQ#What-does-Connection-already-closed-mean
        my $tx = $self->tx;     # NOTE: Keep tx around as long operations could make it disappear

        return Mojo::IOLoop->subprocess(
            sub {
                die "Transaction empty" if $tx->is_empty;
                @{Mojo::IOLoop->singleton}{@ioloop_evs} = @evs;
                Mojo::IOLoop->singleton->emit('chunk_upload.start' => $self);
                my ($e, $fname, $type, $last) = $job->create_asset($self->param('file'), $self->param('asset'));
                Mojo::IOLoop->singleton->emit('chunk_upload.end' => ($self, $e, $fname, $type, $last));
                die "$e" if $e;
                return $fname, $type, $last;
            },
            sub {
                my ($subprocess, $e, @results) = @_;
                # Even if most probably it is an error on client side, we return 500
                # So worker can keep retrying if it was caused by network failures
                $self->app->log->debug($e) if $e;

                $self->render(json => {error => 'Failed receiving chunk: ' . $e}, status => 500) and return if $e;
                my $fname = $results[0];
                my $type  = $results[1];
                my $last  = $results[2];

                $job->jobs_assets->create({job => $job, asset => {name => $fname, type => $type}, created_by => 1})
                  if $last && !$e;
                return $self->render(json => {status => 'ok'});
            });
    }
    if ($job->create_artefact($self->param('file'), $self->param('ulog'))) {
        $self->render(text => "OK");
    }
    else {
        $self->render(text => "FAILED");
    }
}

=over 4

=item upload_state()

It is used by the worker to inform the webui of a failed download. This is the case when
all upload retrials from the worker have been exhausted and webui can remove the file
that has been partially uploaded.

=back

=cut

sub upload_state {
    my ($self) = @_;
    my $file   = $self->param('filename');
    my $state  = $self->param('state');
    my $scope  = $self->param('scope');
    my $job_id = $self->stash('jobid');

    $file = sprintf("%08d-%s", $job_id, $file) if $scope ne 'public';

    if ($state eq 'fail') {
        $self->app->log->debug("FAIL chunk upload of $file");
        path($OpenQA::Utils::assetdir, 'tmp', $scope)->list_tree({dir => 1})->each(
            sub {
                $_->remove_tree if -d $_ && $_->basename eq $file . '.CHUNKS';
            });
    }
    $self->render(text => "OK");
}

=over 4

=item done()

Updates result of a job in the system.

=back

=cut

sub done {
    my ($self) = @_;

    my $job = find_job($self, $self->stash('jobid')) or return;
    my $result = $self->param('result');
    my $newbuild;
    $newbuild = 1 if defined $self->param('newbuild');

    my $res;
    if ($newbuild) {
        $res = $job->done(result => $result, newbuild => $newbuild);
    }
    else {
        $res = $job->done(result => $result);
    }

    # use $res as a result, it is recomputed result by scheduler
    $self->emit_event('openqa_job_done', {id => $job->id, result => $res, newbuild => $newbuild});

    # See comment in prio
    $self->render(json => {result => \$res});
}

=over 4

=item restart()

Restart job or jobs. Used for both apiv1_restart and apiv1_restart_jobs

=back

=cut

sub restart {
    my ($self) = @_;
    my $jobs = $self->param('jobid');
    if ($jobs) {
        $self->app->log->debug("Restarting job $jobs");
        $jobs = [$jobs];
    }
    else {
        $jobs = $self->every_param('jobs');
        $self->app->log->debug("Restarting jobs @$jobs");
    }

    my $ipc = OpenQA::IPC->ipc;
    my $res = $ipc->resourceallocator('job_restart', $jobs);

    my @urls;
    for (my $i = 0; $i < @$res; $i++) {
        my $r = $res->[$i];
        $self->emit_event('openqa_job_restart', {id => $jobs->[$i], result => $r});

        my $url = {};
        for my $k (keys %$r) {
            my $u = $self->url_for('test', testid => $r->{$k});
            $url->{$k} = $u;
        }
        push @urls, $url;
    }
    $self->render(json => {result => $res, test_url => \@urls});
}

=over 4

=item cancel()

Cancel job or jobs. Used for both apiv1_cancel and apiv1_cancel_jobs

=back

=cut

sub cancel {
    my ($self) = @_;
    my $jobid = $self->param('jobid');

    my $ipc = OpenQA::IPC->ipc;
    my $res;
    if ($jobid) {
        my $job = find_job($self, $self->stash('jobid')) or return;
        $job->cancel;
        $self->emit_event('openqa_job_cancel', {id => int($jobid)});
    }
    else {
        my $params = $self->req->params->to_hash;
        $res = $self->db->resultset('Jobs')->cancel_by_settings($params, 0);
        $self->emit_event('openqa_job_cancel_by_settings', $params) if ($res);
    }

    $self->render(json => {result => $res});
}

=over 4

=item duplicate()

Creates a new job as a duplicate of an existing one given its job id.

=back

=cut

sub duplicate {
    my ($self) = @_;

    my $jobid = int($self->param('jobid'));
    my $job = find_job($self, $self->stash('jobid')) or return;
    my $args;
    if (defined $self->param('prio')) {
        $args->{prio} = int($self->param('prio'));
    }
    if (defined $self->param('dup_type_auto')) {
        $args->{dup_type_auto} = 1;
    }

    my $dup = $job->auto_duplicate($args);
    if ($dup) {
        $self->emit_event(
            'openqa_job_duplicate',
            {
                id     => $job->id,
                auto   => $args->{dup_type_auto} // 0,
                result => $dup->id
            });
        $self->render(json => {id => $dup->id});
    }
    else {
        $self->render(json => {});
    }
}

=over 4

=item whoami()

Returns the job id of the current job.

=back

=cut

sub whoami {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');
    $self->render(json => {id => $jobid});
}

1;
# vim: set sw=4 et:
