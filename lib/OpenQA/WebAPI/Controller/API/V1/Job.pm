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
use OpenQA::ExpandPlaceholder;
use OpenQA::Jobs::Constants;
use OpenQA::Resource::Jobs;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Events;
use OpenQA::Scheduler::Client;
use Try::Tiny;
use DBIx::Class::Timestamps 'now';
use Mojo::Asset::Memory;
use Mojo::File 'path';

use constant JOB_QUERY_LIMIT => 10000;

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

These options are currently available:

=over 4

=item latest

  latest => 1

De-duplicate so that for the same DISTRI, VERSION, BUILD, TEST, FLAVOR, ARCH and MACHINE
only the latest job is returned.

=item scope

  scope => relevant

Only pending, not obsoleted jobs are included in the results.

  scope => current

Clones are excluded from the results.

=item limit

  limit => 100

Limit the number of jobs.

=back

=back

=cut

sub list {
    my $self = shift;

    my %args;
    my @args = qw(build iso distri version flavor maxage scope group
      groupid limit page before after arch hdd_1 test machine worker_class
      failed_modules modules modules_result);
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

    # ensure the query does not become too big
    if (my $limit = $args{limit}) {
        return $self->render(json => {error => 'limit is not an unsigned number'}, status => 400)
          unless $limit =~ qr/^\d+$/;
        return $self->render(json => {error => 'limit exceeds maximum'}, status => 400)
          unless $limit <= JOB_QUERY_LIMIT;
    }
    else {
        $args{limit} = JOB_QUERY_LIMIT;
    }

    my $schema = $self->schema;
    my $rs     = $schema->resultset('Jobs')->complex_query(%args);
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
    my $jas = $schema->resultset('JobsAssets')->search({job_id => {in => [keys %jobs]}}, {prefetch => ['asset']});
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

    my $modules = $schema->resultset('JobModules')->search({job_id => {in => [keys %jobs]}}, {order_by => 'id'});
    while (my $m = $modules->next) {
        my $job = $jobs{$m->job_id};
        $job->{_modules} ||= [];
        push(@{$job->{_modules}}, $m);
    }

    my @results;
    for my $id (sort keys %jobs) {
        my $job     = $jobs{$id};
        my $jobhash = $job->to_hash(assets => 1, deps => 1);
        $jobhash->{modules} = [];
        for my $module (@{$job->{_modules}}) {
            my $modulehash = {
                name     => $module->name,
                category => $module->category,
                result   => $module->result,
                flags    => []};
            for my $flag (qw(important fatal milestone always_rollback)) {
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
    my $failed_modules = OpenQA::Utils::param_hash($self, 'failed_modules');
    my $states         = OpenQA::Utils::param_hash($self, 'state');
    my $results        = OpenQA::Utils::param_hash($self, 'result');

    my @jobs = $self->schema->resultset('Jobs')->complex_query(%$search_args)->latest_jobs;

    my @job_hashes;
    for my $job (@jobs) {
        next if $states  && !$states->{$job->state};
        next if $results && !$results->{$job->result};
        if ($failed_modules) {
            next if $job->result ne OpenQA::Jobs::Constants::FAILED;
            next unless OpenQA::Utils::any_array_item_contained_by_hash($job->failed_modules, $failed_modules);
        }
        push(
            @job_hashes,
            {
                id   => $job->id,
                name => $job->name,
            });
    }
    $self->render(json => \@job_hashes);
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
    my $result = $self->_generate_job_setting(\%params);
    return $self->render(json => {error => $result->{error_message}}, status => 400)
      if defined $result->{error_message};

    try {
        my $job = $self->schema->resultset('Jobs')->create_from_settings($result->{settings_result});
        $self->emit_event('openqa_job_create', {id => $job->id, %params});
        $json->{id} = $job->id;

        # enqueue gru jobs
        my $downloads = create_downloads_list(\%params);
        my $gru       = $self->gru;
        $gru->enqueue_download_jobs($downloads, [$job->id]);
        $gru->enqueue_limit_assets;
        $job->calculate_blocked_by;
        OpenQA::Scheduler::Client->singleton->wakeup;
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
    my $job     = $self->schema->resultset("Jobs")->search({'me.id' => $job_id}, {prefetch => 'settings'})->first;
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

    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
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
    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
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
    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
    my $result = $self->param('result');

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

    return $self->render(json => {error => 'No status information provided'}, status => 400)
      unless my $json = $self->req->json;

    my $status = $json->{status};
    my $job_id = $self->stash('jobid');
    my $job    = $self->schema->resultset('Jobs')->find($job_id);
    if (!$job) {
        my $err = 'Got status update for non-existing job: ' . $job_id;
        OpenQA::Utils::log_info($err);
        return $self->render(json => {error => $err}, status => 400);
    }

    my $worker_id = $status->{worker_id};
    if (!defined $worker_id) {
        my $err = "Got status update for job $job_id but does not contain a worker id!";
        OpenQA::Utils::log_info($err);
        return $self->render(json => {error => $err}, status => 400);
    }

    # find worker
    # - use either the worker which is known to execute the current job right now
    # - or use the assigned worker if the job is still running
    my $worker = $job->worker;
    my $use_assigned_worker;
    if (!$worker && !defined $job->t_finished) {
        if (my $assigned_worker = $job->assigned_worker) {
            $worker              = $assigned_worker;
            $use_assigned_worker = 1;
        }
        else {
            my $job_status = $job->status_info;
            my $err        = "Got status update for job $job_id and worker $worker_id but there is"
              . " not even a worker assigned to this job (job is $job_status)";
            log_info($err);
            return $self->render(json => {error => $err}, status => 400);
        }
    }

    if (!$worker || $worker->id != $worker_id) {
        my $expected_worker_id = $worker ? $worker->id : 'no updates anymore';
        my $job_status         = $job->status_info;
        my $err
          = "Got status update for job $job_id with unexpected worker ID $worker_id"
          . " (expected $expected_worker_id, job is $job_status)";
        OpenQA::Utils::log_info($err);
        return $self->render(json => {error => $err}, status => 400);
    }

    $worker->update({job_id => $job->id}) if $use_assigned_worker;

    my $ret;
    try {
        $ret = $job->update_status($status);
    }
    catch {
        my $error_message = $_;
        my $worker_name   = $worker->name;
        $ret = {error => $error_message};
        OpenQA::Utils::log_error(
            "Unexpected error when updating job $job_id executed by worker $worker_name: $error_message");
    };
    if (!$ret || $ret->{error} || $ret->{error_status}) {
        $ret = {} unless $ret;
        $ret->{error}        //= 'Unable to update status';
        $ret->{error_status} //= 400;
        return $self->render(json => {error => $ret->{error}}, status => $ret->{error_status});
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

    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
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
    my $schema   = $self->schema;
    my $group_id = $json->{group_id};
    if (defined($group_id) && !$schema->resultset('JobGroups')->find(int($group_id))) {
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
        $schema->resultset('JobSettings')->search({job_id => $job->id, key => {-not_in => \@settings_keys}})->delete;
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
    my $job   = $self->schema->resultset('Jobs')->find($jobid);
    if (!$job) {
        OpenQA::Utils::log_info('Got artefact for non-existing job: ' . $jobid);
        return $self->render(json => {error => "Specified job $jobid does not exist"}, status => 404);
    }
    if (!$job->worker) {
        OpenQA::Utils::log_info(
            'Got artefact for job with no worker assigned (maybe running job already considered dead): ' . $jobid);
        return $self->render(json => {error => 'No worker assigned'}, status => 404);
    }
    # mark the worker as alive
    $job->worker->seen;

    if ($self->param('image')) {
        $job->store_image($self->param('file'), $self->param('md5'), $self->param('thumb') // 0);
        return $self->render(text => "OK");
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
                OpenQA::Events->singleton->emit('chunk_upload.start' => $self);
                my ($e, $fname, $type, $last) = $job->create_asset($self->param('file'), $self->param('asset'));
                OpenQA::Events->singleton->emit('chunk_upload.end' => ($self, $e, $fname, $type, $last));
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

    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
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

    my @res = OpenQA::Resource::Jobs::job_restart($jobs);
    OpenQA::Scheduler::Client->singleton->wakeup;

    my @urls;
    for (my $i = 0; $i < @res; $i++) {
        my $r = $res[$i];
        $self->emit_event('openqa_job_restart', {id => $jobs->[$i], result => $r});

        my $url = {};
        for my $k (keys %$r) {
            my $u = $self->url_for('test', testid => $r->{$k});
            $url->{$k} = $u;
        }
        push @urls, $url;
    }
    $self->render(json => {result => \@res, test_url => \@urls});
}

=over 4

=item cancel()

Cancel job or jobs. Used for both apiv1_cancel and apiv1_cancel_jobs

=back

=cut

sub cancel {
    my ($self) = @_;
    my $jobid = $self->param('jobid');

    my $res;
    if ($jobid) {
        return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
        $job->cancel;
        $self->emit_event('openqa_job_cancel', {id => int($jobid)});
    }
    else {
        my $params = $self->req->params->to_hash;
        $res = $self->schema->resultset('Jobs')->cancel_by_settings($params, 0);
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
    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
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

=over 4

=item _generate_job_setting()

Create job for product matching the contents of the DISTRI, VERSION, FLAVOR and ARCH, MACHINE
settings, and returns a job's settings. Internal method used in the B<create()> method.

=back

=cut

sub _generate_job_setting {
    my ($self, $args) = @_;
    my $schema = $self->schema;

    my %settings;    # Machines, product and test suite settings for the job
    my @classes;     # Populated with WORKER_CLASS settings from machines and products

    # Populated with Product settins if there are DISTRI, VERSION, FLAVOR, ARCH in arguments.
    if (   defined $args->{DISTRI}
        && defined $args->{VERSION}
        && defined $args->{FLAVOR}
        && defined $args->{ARCH})
    {
        my $products = $schema->resultset('Products')->search(
            {
                distri  => $args->{DISTRI},
                version => $args->{VERSION},
                arch    => $args->{ARCH},
                flavor  => $args->{FLAVOR},
            });

        if (my $product = $products->next) {
            my %tmp_setting = map { $_->key => $_->value } $product->settings;

            if (my $class = delete $tmp_setting{WORKER_CLASS}) {
                push @classes, $class;
            }
            @settings{keys %tmp_setting} = values %tmp_setting;
        }
    }

    # Populated with machine settings if there is MACHINE in arguments.
    if (defined $args->{MACHINE}) {
        my $machines = $schema->resultset('Machines')->search(
            {
                name => $args->{MACHINE},
            });

        if (my $machine = $machines->next) {
            my %tmp_setting = map { $_->key => $_->value } $machine->settings;

            if (my $class = delete $tmp_setting{WORKER_CLASS}) {
                push @classes, $class;
            }
            @settings{keys %tmp_setting} = values %tmp_setting;
        }
    }

    # TEST is mandatory, so populate with TestSuite settings.
    my $test_suites = $schema->resultset('TestSuites')->search(
        {
            name => $args->{TEST},
        });

    if (my $test_suite = $test_suites->next) {
        my %test_suite_setting = map { $_->key => $_->value } $test_suite->settings;

        if (my $test_suite_class = delete $test_suite_setting{WORKER_CLASS}) {
            push @classes, $test_suite_class;
        }
        @settings{keys %test_suite_setting} = values %test_suite_setting;
    }

    $settings{WORKER_CLASS} = join ',', sort @classes if @classes > 0;

    for (keys %$args) {
        $settings{uc $_} = $args->{$_};
    }

    my $error_message = OpenQA::ExpandPlaceholder::expand_placeholders(\%settings);
    return {error_message => $error_message, settings_result => \%settings};
}

1;
