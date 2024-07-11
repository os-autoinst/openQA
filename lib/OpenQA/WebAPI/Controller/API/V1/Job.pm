# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Job;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use OpenQA::App;
use OpenQA::Utils qw(:DEFAULT assetdir);
use OpenQA::JobSettings;
use OpenQA::Jobs::Constants;
use OpenQA::JobDependencies::Constants qw(CHAINED PARALLEL DIRECTLY_CHAINED);
use OpenQA::Resource::Jobs;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Events;
use OpenQA::Scheduler::Client;
use OpenQA::Log qw(log_error log_info);
use List::Util qw(min);
use Scalar::Util qw(looks_like_number);
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

sub list ($self) {
    my $validation = $self->validation;
    $validation->optional('scope')->in('current', 'relevant');
    $validation->optional('latest')->num(1);
    $validation->optional('limit')->num;
    $validation->optional('offset')->num;
    $validation->optional('groupid')->num;

    my $limits = OpenQA::App->singleton->config->{misc_limits};
    my $limit = min($limits->{generic_max_limit}, $validation->param('limit') // $limits->{generic_default_limit});
    my $offset = $validation->param('offset') // 0;
    return $self->render(json => {error => 'Limit exceeds maximum'}, status => 400) unless $limit;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    # validate parameters
    # note: When updating parameters, be sure to update the "Finding tests" section within
    #       docs/UsersGuide.asciidoc accordingly.
    my %args;
    $args{limit} = $limit + 1;
    $args{offset} = $offset;
    my @args = qw(build iso distri version flavor scope group groupid
      before after arch hdd_1 test machine worker_class
      modules modules_result);
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
        next unless defined(my $value = $self->param($arg));
        my $values = $args{$arg} = index($value, ',') != -1 ? [split(',', $value)] : $self->every_param($arg);
        if ($arg eq 'ids') {
            for my $id (@$values) {
                return $self->render(json => {error => 'ids must be integers'}, status => 400)
                  unless looks_like_number $id;
            }
        }
    }

    my $latest = $validation->param('latest');
    my $schema = $self->schema;
    my $rs = $schema->resultset('Jobs')->complex_query(%args);
    my @jobarray = defined $latest ? $rs->latest_jobs : $rs->all;

    # Pagination
    pop @jobarray if my $has_more = @jobarray > $limit;
    $self->pagination_links_header($limit, $offset, $has_more) unless defined $latest;
    my %jobs = map { $_->id => $_ } @jobarray;

    # we can't prefetch too much at once as the resulting JOIN will kill our performance horribly
    # (not so much the JOIN itself, but parsing the result containing duplicated information)
    # so we fetch some fields in a second step

    # fetch job assets
    $_->{_assets} = [] for values %jobs;
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

    my @jobids = sort keys %jobs;

    # prefetch data from several tables
    my (%children, %parents, %settings, %origins);
    my $s = $schema->resultset('JobDependencies')->search(
        {
            -or => [
                parent_job_id => {-in => \@jobids},
                child_job_id => {-in => \@jobids},
            ],
        });
    while (my $dep = $s->next) {
        push @{$children{$dep->parent_job_id}}, $dep;
        push @{$parents{$dep->child_job_id}}, $dep;
    }
    my $js
      = $schema->resultset('JobSettings')
      ->search(\['job_id = ANY(?)', [{}, \@jobids]], {select => [qw(job_id key value)]});
    while (my $set = $js->next) {
        push @{$settings{$set->job_id}}, $set;
    }
    my $o = $schema->resultset('Jobs')->search(\['clone_id = ANY(?)', [{}, \@jobids]], {select => [qw(id clone_id)]});
    while (my $orig = $o->next) {
        $origins{$orig->clone_id} = $orig->id;
    }

    my @results;
    for my $id (@jobids) {
        my $job = $jobs{$id};
        my $jobhash = $job->to_hash(
            assets => 1,
            deps => 1,
            dependencies => {children => $children{$id}, parents => $parents{$id}},
            settings => $settings{$id},
            origin => $origins{$id},
        );
        $jobhash->{modules} = [];
        for my $module (@{$job->{_modules}}) {
            my $modulehash = {
                name => $module->name,
                category => $module->category,
                result => $module->result,
                flags => []};
            for my $flag (qw(important fatal milestone always_rollback)) {
                push(@{$modulehash->{flags}}, $flag) if $module->get_column($flag);
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

sub overview ($self) {
    my ($search_args, $groups) = $self->compose_job_overview_search_args;
    my $failed_modules = $self->param_hash('failed_modules');
    my $states = $self->param_hash('state');
    my $results = $self->param_hash('result');
    my $archs = $self->param_hash('arch');
    my $machines = $self->param_hash('machine');

    my @jobs = $self->schema->resultset('Jobs')->complex_query(%$search_args)->latest_jobs;

    my @job_hashes;
    for my $job (@jobs) {
        next if $states && !$states->{$job->state};
        next if $results && !$results->{$job->result};
        next if $archs && !$archs->{$job->ARCH};
        next if $machines && !$machines->{$job->MACHINE};
        if ($failed_modules) {
            next if $job->result ne OpenQA::Jobs::Constants::FAILED;
            next unless OpenQA::Utils::any_array_item_contained_by_hash($job->failed_modules, $failed_modules);
        }
        push(
            @job_hashes,
            {
                id => $job->id,
                name => $job->name,
            });
    }
    $self->render(json => \@job_hashes);
}

=over 4

=item _eval_param_grouping()

Removes job-specific parameters from the specified hash and returns a new hash
containing the removed parameters (where the keys are job suffixes).

So "{foo => 1, bar:jobA => 2, baz:jobB => 3}" will be turned into "{foo => 1}"
returning "{jobA => {bar => 2}, jobB => {baz => 3}}".

=back

=cut

sub _eval_param_grouping ($params) {
    my %grouped_params;
    for my $param_key (keys %$params) {
        my $job_suffix_start = rindex($param_key, ':');
        next unless $job_suffix_start >= 0;
        my $job_suffix = substr $param_key, $job_suffix_start + 1;
        my $setting_key = substr $param_key, 0, $job_suffix_start;
        $grouped_params{$job_suffix}->{$setting_key} = delete $params->{$param_key};
    }
    return \%grouped_params;
}

=over 4

=item _eval_dependency()

Removes the specified $settings_keys from $job_settings populating $self->{_dependencies}
with the dependency information from the removed hash entry value.

=back

=cut

sub _eval_dependency ($self, $child_job_suffix, $job_settings, $setting_key, $type) {
    return undef unless defined $child_job_suffix;
    my $job_suffixes = delete $job_settings->{$setting_key};
    return undef unless defined $job_suffixes;
    my $deps = $self->{_dependencies};
    for my $parent_job_suffix (split /\s*,\s*/, $job_suffixes) {
        push @$deps,
          {
            child_job_id => $child_job_suffix,
            parent_job_id => $parent_job_suffix,
            dependency => $type,
          };
    }
}

=over 4

=item _create_job()

Creates a single job. The parameters $global_params and $job_specific_params will
be merged ($job_specific_params takes precedence).

=back

=cut

sub _create_job ($self, $global_params, $job_suffix = undef, $job_specific_params = {}) {
    # job_create expects upper case keys
    my %up_params = map { uc $_ => $global_params->{$_} } keys %$global_params;
    $up_params{uc $_} = $job_specific_params->{$_} for keys %$job_specific_params;

    # restore URL encoded /
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;
    die "TEST field mandatory\n" unless $params{TEST};

    # create job
    my $job_settings = \%params;
    if (!$self->{_is_clone_job}) {
        my $result = $self->_generate_job_setting(\%params);
        die "$result->{error_message}\n" if defined $result->{error_message};
        $job_settings = $result->{settings_result};
    }
    my $downloads = create_downloads_list($job_settings);
    $self->_eval_dependency($job_suffix, $job_settings, _START_AFTER => CHAINED);
    $self->_eval_dependency($job_suffix, $job_settings, _START_DIRECTLY_AFTER => DIRECTLY_CHAINED);
    $self->_eval_dependency($job_suffix, $job_settings, _PARALLEL => PARALLEL);
    my $job = $self->schema->resultset('Jobs')->create_from_settings($job_settings);
    my $job_id = $job->id;
    my $json = $self->{_json};
    (defined $job_suffix ? $json->{ids}->{$job_suffix} : $json->{id}) = $job_id;
    push @{$self->{_event_data}}, {id => $job_id, %params};

    # enqueue gru jobs and calculate blocked by
    push @{$downloads->{$_}}, [$job_id] for keys %$downloads;
    $self->gru->enqueue_download_jobs($downloads);
    my $clones = create_git_clone_list($job_settings);
    $self->gru->enqueue_git_clones($clones, [$job_id]) if keys %$clones;
    return $job_id;
}

sub _turn_suffix_into_job_id ($ids, $dep, $key) {
    my $job_suffix = $dep->{$key};
    die "Specified dependency '$job_suffix' does not relate to a present job-suffix.\n"
      unless my $job_id = $ids->{$job_suffix};
    $dep->{$key} = $job_id;
}

=over 4

=item _create_dependencies()

Creates dependencies from $self->{_dependencies} within the database.

=back

=cut

sub _create_dependencies ($self) {
    my $deps = $self->{_dependencies};
    my $ids = $self->{_json}->{ids};
    return undef unless @$deps;
    my $job_dependencies = $self->schema->resultset('JobDependencies');
    for my $dep (@$deps) {
        _turn_suffix_into_job_id($ids, $dep, $_) for qw(child_job_id parent_job_id);
        $job_dependencies->create($dep);
    }
    my $jobs = $self->schema->resultset('Jobs');
    $jobs->find($_)->calculate_blocked_by for values %$ids;
}

=over 4

=item _create_jobs()

Creates jobs for the specified parameters and their dependencies. At least one job is created, even
if $grouped_params is empty.

=back

=cut

sub _create_jobs ($self, $global_params, $grouped_params) {
    if (keys %$grouped_params) {
        # create as many jobs as unique ":"-suffixes exist
        $self->_create_job($global_params, $_, $grouped_params->{$_}) for keys %$grouped_params;
    }
    else {
        # create a single job if there are no job-specific parameters
        $self->_create_job($global_params);
    }
    $self->_create_dependencies;
}

=over 4

=item create()

Creates jobs given a list of settings passed as parameters. TEST setting/parameter
is mandatory and should be the name of the test.

=back

=cut

sub create ($self) {
    my $global_params = $self->req->params->to_hash;
    $self->{_is_clone_job} = delete $global_params->{is_clone_job} // 0;
    my $grouped_params = _eval_param_grouping($global_params);
    my $json = $self->{_json} = {};
    my $event_data = $self->{_event_data} = [];
    my $dependencies = $self->{_dependencies} = [];
    try {
        $self->schema->txn_do(sub { $self->_create_jobs($global_params, $grouped_params) });
        OpenQA::Scheduler::Client->singleton->wakeup;
    }
    catch {
        my $error = $_;
        chomp $error;
        $json->{error} = $error;
        delete $json->{id};
        delete $json->{ids};
    };

    $self->emit_event(openqa_job_create => $_) for @$event_data;
    $self->render(json => $json, status => ($json->{error} ? 400 : 200));
}

=over 4

=item show()

Shows details for a specific job, such as the assets associated, assigned worker id,
children and parents, job id, group id, name, parent group id and name, priority, result,
settings, state and times of startup and finish of the job.

=back

=cut

sub show ($self) {
    my $job_id = int($self->stash('jobid'));
    my $details = $self->stash('details') || 0;
    my $check_assets = !!$self->param('check_assets');
    my $job = $self->schema->resultset('Jobs')->find($job_id, {prefetch => 'settings'});
    return $self->reply->not_found unless $job;
    $job = $job->to_hash(assets => 1, check_assets => $check_assets, deps => 1, details => $details, parent_group => 1);
    $self->render(json => {job => $job});
}

=over 4

=item destroy()

Deletes a job from the system.

=back

=cut

sub destroy ($self) {
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

sub prio ($self) {
    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
    my $res = $job->set_prio($self->param('prio'));

    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
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
sub update_status ($self) {
    return $self->render(json => {error => 'No status information provided'}, status => 400)
      unless my $json = $self->req->json;

    my $status = $json->{status};
    my $job_id = $self->stash('jobid');
    my $job = $self->schema->resultset('Jobs')->find($job_id);
    if (!$job) {
        my $err = 'Got status update for non-existing job: ' . $job_id;
        log_info($err);
        return $self->render(json => {error => $err}, status => 400);
    }

    my $worker_id = $status->{worker_id};
    if (!defined $worker_id) {
        my $err = "Got status update for job $job_id but does not contain a worker id!";
        log_info($err);
        return $self->render(json => {error => $err}, status => 400);
    }

    # find worker
    # - use either the worker which is known to execute the current job right now
    # - or use the assigned worker if the job is still running
    my $worker = $job->worker;
    my $use_assigned_worker;
    if (!$worker && !defined $job->t_finished) {
        if (my $assigned_worker = $job->assigned_worker) {
            $worker = $assigned_worker;
            $use_assigned_worker = 1;
        }
        else {
            my $job_status = $job->status_info;
            my $err = "Got status update for job $job_id and worker $worker_id but there is"
              . " not even a worker assigned to this job (job is $job_status)";
            log_info($err);
            return $self->render(json => {error => $err}, status => 400);
        }
    }

    if (!$worker || $worker->id != $worker_id) {
        my $expected_worker_id = $worker ? $worker->id : 'no updates anymore';
        my $job_status = $job->status_info;
        my $err
          = "Got status update for job $job_id with unexpected worker ID $worker_id"
          . " (expected $expected_worker_id, job is $job_status)";
        log_info($err);
        return $self->render(json => {error => $err}, status => 400);
    }

    # update worker and job status
    my $ret;
    try {
        $worker->update({job_id => $job->id}) if $use_assigned_worker;
        $worker->seen;
        $ret = $job->update_status($status);
    }
    catch {
        # uncoverable statement
        my $error_message = $_;
        # uncoverable statement
        my $worker_name = $worker->name;
        # uncoverable statement
        $ret = {error => $error_message};
        # uncoverable statement
        log_error("Unexpected error when updating job $job_id executed by worker $worker_name: $error_message");
    };
    if (!$ret || $ret->{error} || $ret->{error_status}) {
        $ret = {} unless $ret;
        $ret->{error} //= 'Unable to update status';
        $ret->{error_status} //= 400;
        return $self->render(json => {error => $ret->{error}}, status => $ret->{error_status});
    }
    $self->render(json => $ret);
}

=over 4

=item get_status()

Retrieve status of a job. Returns id, state, result, blocked_by_id.
Preferable over /job/<id> for performance and payload size, if you are only
interested in the status.

=back

=cut

sub get_status ($self) {
    my @fields = qw(id state result blocked_by_id);
    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
    $self->render(json => {map { $_ => $job->$_ } @fields});
}

=over 4

=item update()

Updates the settings of a job with information specified in a passed JSON argument.
Columns group_id and priority cannot be set.

=back

=cut

sub update ($self) {
    return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
    my $json = $self->req->json;
    return $self->render(json => {error => 'No updates provided (must be provided as JSON)'}, status => 400)
      unless $json;
    my $settings = delete $json->{settings};

    # validate specified columns (print error if at least one specified column does not exist)
    my @allowed_cols = qw(group_id priority);
    for my $key (keys %$json) {
        return $self->render(json => {error => "Column $key can not be set"}, status => 400)
          unless grep $_ eq $key, @allowed_cols;
    }

    # validate specified group
    my $schema = $self->schema;
    my $group_id = $json->{group_id};
    return $self->render(json => {error => 'Group does not exist'}, status => 404)
      if defined($group_id) && !$schema->resultset('JobGroups')->find(int($group_id));

    # some settings are stored directly in job table and hence must be updated there
    my @setting_cols = qw(TEST DISTRI VERSION FLAVOR ARCH BUILD MACHINE);
    if ($settings) { $json->{$_} = delete $settings->{$_} // '' for @setting_cols }
    $job->update($json);

    if ($settings) {
        # update settings stored in extra job settings table
        my @settings_keys = keys %$settings;
        $job->set_property($_, $settings->{$_}) for @settings_keys;
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

sub create_artefact ($self) {
    my $jobid = int($self->stash('jobid'));
    my $schema = $self->schema;
    my $job = $schema->resultset('Jobs')->find($jobid);
    if (!$job) {
        log_info('Got artefact for non-existing job: ' . $jobid);
        return $self->render(json => {error => "Specified job $jobid does not exist"}, status => 404);
    }

    # mark the worker as alive
    if (my $worker = $job->worker) {
        $worker->seen;
    }
    else {
        log_info('Got artefact for job with no worker assigned (maybe running job already considered dead): ' . $jobid);
        return $self->render(json => {error => 'No worker assigned'}, status => 404);
    }

    # validate parameters
    my $validation = $self->validation;
    $validation->required('file');
    $validation->upload unless $self->param('local');
    $validation->required('md5')->like(qr/^[a-fA-F0-9]{32}$/) if $self->param('image');
    if ($self->param('extra_test')) {
        $validation->required('type');
        $validation->required('script');
    }
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    if ($self->param('image')) {
        $job->store_image($validation->param('file'), $validation->param('md5'), $self->param('thumb') // 0);
        return $self->render(text => 'OK');
    }
    elsif ($self->param('extra_test')) {
        return $self->render(text => 'OK')
          if $job->parse_extra_tests($validation->param('file'), $validation->param('type'),
            $validation->param('script'));
        return $self->render(json => {error => 'Unable to parse extra test'}, status => 400);
    }
    elsif (my $scope = $self->param('asset')) {
        my ($error, $fname, $type, $last)
          = $job->create_asset($validation->param('file'), $scope, $self->param('local'));
        if ($error) {
            # return 500 even if most probably it is an error on client side so the worker can keep retrying if it was
            # caused by network failures
            $self->app->log->debug($error);
            return $self->render(json => {error => "Failed receiving asset: $error"}, status => 500);
        }
        my $assets = $schema->resultset('Assets');
        $assets->register($type, $fname, {scope => $scope, created_by => $job, refresh_size => 1}) if $last;
        return $self->render(json => {status => 'ok'});
    }
    $job->create_artefact($validation->param('file'), $self->param('ulog'));
    $self->render(text => 'OK');
}

=over 4

=item upload_state()

It is used by the worker to inform the webui of a failed download. This is the case when
all upload retries from the worker have been exhausted and webui can remove the file
that has been partially uploaded.

=back

=cut

sub upload_state ($self) {
    my $validation = $self->validation;
    $validation->required('filename');
    $validation->required('state');
    # private or public, handled as an event in Upload.pm
    $validation->required('scope');
    return $self->reply->validation_error if $validation->has_error;

    my $file = $validation->param('filename');
    my $state = $validation->param('state');
    my $scope = $validation->param('scope') // 'private';
    my $job_id = $self->stash('jobid');

    $file = sprintf('%08d-%s', $job_id, $file) if $scope ne 'public';

    if ($state eq 'fail') {
        $self->app->log->debug("FAIL chunk upload of $file");
        path(assetdir(), 'tmp', $scope)->list_tree({dir => 1})->each(
            sub {
                $_->remove_tree if -d $_ && $_->basename eq $file . '.CHUNKS';
            });
    }
    $self->render(text => 'OK');
}

=over 4

=item done()

Updates result of a job in the system.

=back

=cut

sub done ($self) {
    return undef unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));

    my $validation = $self->validation;
    # This must be within the RESULTS constant. We're not checking it here, though,
    # because the done() function in Schema/Result/Jobs.pm already validates it.
    $validation->optional('result');
    $validation->optional('reason');
    $validation->optional('newbuild')->num(1);
    $validation->optional('worker_id')->num(0, undef);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    # check whether the specified worker matches the actually assigned one; refuse the update if not
    if (my $specified_worker_id = $validation->param('worker_id')) {
        my $assigned_worker_id = $job->assigned_worker_id;
        my $msg = (
            defined $assigned_worker_id
            ? (
                $assigned_worker_id != $specified_worker_id
                ? "Refusing to set result because job is currently assigned to worker $assigned_worker_id)."
                : undef
              )
            : 'Refusing to set result because job has already been re-scheduled.'
        );
        return $self->render(status => 400, json => {error => $msg}) if $msg;
    }

    my $result = $validation->param('result');
    my $reason = $validation->param('reason');
    my $newbuild = defined $validation->param('newbuild') ? 1 : undef;
    my $res;
    try {
        $res = $job->done(result => $result, reason => $reason, newbuild => $newbuild);
    }
    catch {
        $self->render(status => 400, json => {error => $_});
    };
    return undef unless $res;

    # use $res as a result, it is recomputed result by scheduler
    $self->emit_event('openqa_job_done', {id => $job->id, result => $res, reason => $reason, newbuild => $newbuild});

    $self->render(json => {result => $res, reason => $reason});
}

sub _restart ($self, %args) {
    my $dup_route = $args{duplicate_route_compatibility};
    my @flags = qw(force skip_aborting_jobs skip_parents skip_children skip_ok_result_children);
    my $validation = $self->validation;
    $validation->optional('clone')->num(0);
    $validation->optional('prio')->num;
    $validation->optional('dup_type_auto')->num(0);    # recorded within the event; for informal purposes only
    $validation->optional('jobid')->num(0);
    $validation->optional('jobs');
    $validation->optional('set')->like(qr/.+=.*/);
    $validation->optional($_)->num(0) for @flags;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $jobs = $self->param('jobid');
    my $single_job_id;
    if ($jobs) {
        $self->app->log->debug("Restarting job $jobs");
        $jobs = [$jobs];
        $single_job_id = $jobs->[0];
    }
    else {
        $jobs = $self->every_param('jobs');
        $self->app->log->debug("Restarting jobs @$jobs");
    }

    my $auto = defined $validation->param('dup_type_auto') ? int($validation->param('dup_type_auto')) : 0;
    my %settings = map { split('=', $_, 2) } @{$validation->every_param('set')};
    my @params = map { $validation->param($_) ? ($_ => 1) : () } @flags;
    push @params, clone => !defined $validation->param('clone') || $validation->param('clone');
    push @params, prio => int($validation->param('prio')) if defined $validation->param('prio');
    push @params, skip_aborting_jobs => 1 if $dup_route && !defined $validation->param('skip_aborting_jobs');
    push @params, force => 1 if $dup_route && !defined $validation->param('force');
    push @params, settings => \%settings;

    my $res = OpenQA::Resource::Jobs::job_restart($jobs, @params);
    OpenQA::Scheduler::Client->singleton->wakeup;

    my $duplicates = $res->{duplicates};
    my @urls;
    for (my $i = 0; $i < @$duplicates; $i++) {
        my $result = $duplicates->[$i];
        $self->emit_event(openqa_job_restart => {id => $jobs->[$i], result => $result, auto => $auto});
        push @urls, {map { $_ => $self->url_for('test', testid => $result->{$_}) } keys %$result};
    }

    my $clone_id = ($dup_route && $single_job_id) ? ($duplicates->[0] // {})->{$single_job_id} : undef;
    $self->render(
        json => {
            result => $duplicates,
            test_url => \@urls,
            defined $clone_id ? (id => $clone_id) : (),
            @{$res->{warnings}} ? (warnings => $res->{warnings}) : (),
            @{$res->{errors}} ? (errors => $res->{errors}) : (),
            $res->{enforceable} ? (enforceable => 1) : (),
        });
}

=over 4

=item restart()

Restart job(s).

Use force=1 to force the restart (e.g. despite missing assets).
Use prio=X to set the priority of the new jobs.
Use skip_aborting_jobs=1 to prevent aborting the old jobs if they would still be running.
Use skip_parents=1 to prevent restarting parent jobs.
Use skip_children=1 to prevent restarting child jobs.
Use skip_ok_result_children=1 to prevent restarting passed/softfailed child jobs.

Used for both apiv1_restart and apiv1_restart_jobs

=back

=cut

sub restart ($self) { $self->_restart }

=over 4

=item duplicate()

The same as the restart route except that running jobs are not aborted and there's no check for missing assets
by default. This route is only supposed to be used by the worker itself when it is already in the process of
aborting the job.

=back

=cut

sub duplicate ($self) { $self->_restart(duplicate_route_compatibility => 1) }

=over 4

=item cancel()

Cancel job or jobs.

Used for both apiv1_cancel and apiv1_cancel_jobs

=back

=cut

sub cancel ($self) {
    my $jobid = $self->param('jobid');
    my $reason = $self->param('reason');

    my $res;
    if ($jobid) {
        return unless my $job = $self->find_job_or_render_not_found($self->stash('jobid'));
        $job->cancel(OpenQA::Jobs::Constants::USER_CANCELLED, $reason);
        $self->emit_event('openqa_job_cancel', {id => int($jobid), reason => $reason});
    }
    else {
        my $params = $self->req->params->to_hash;
        $res = $self->schema->resultset('Jobs')->cancel_by_settings($params, 0);
    }

    $self->render(json => {result => $res});
}

=over 4

=item whoami()

Returns the job id of the current job.

=back

=cut

sub whoami ($self) {
    my $jobid = $self->stash('job_id');
    $self->render(json => {id => $jobid});
}

=over 4

=item _generate_job_setting()

Create job for product matching the contents of the DISTRI, VERSION, FLAVOR and ARCH, MACHINE
settings, and returns a job's settings. Internal method used in the B<create()> method.

=back

=cut

sub _generate_job_setting ($self, $args) {
    my $schema = $self->schema;

    my %settings;    # Machines, product and test suite settings for the job
    my @classes;    # Populated with WORKER_CLASS settings from machines and products
    my %params = (input_args => $args, settings => \%settings);

    # Populated with Product settings if there are DISTRI, VERSION, FLAVOR, ARCH in arguments.
    if (   defined $args->{DISTRI}
        && defined $args->{VERSION}
        && defined $args->{FLAVOR}
        && defined $args->{ARCH})
    {
        my $products = $schema->resultset('Products')->search(
            {
                distri => $args->{DISTRI},
                version => $args->{VERSION},
                arch => $args->{ARCH},
                flavor => $args->{FLAVOR},
            });
        if (my $product = $products->next) {
            $params{product} = $product;
        }
    }

    # Populated with machine settings if there is MACHINE in arguments.
    if (defined $args->{MACHINE}) {
        my $machines = $schema->resultset('Machines')->search(
            {
                name => $args->{MACHINE},
            });
        if (my $machine = $machines->next) {
            $params{machine} = $machine;
        }
    }

    # TEST is mandatory, so populate with TestSuite settings.
    my $test_suites = $schema->resultset('TestSuites')->search(
        {
            name => $args->{TEST},
        });
    if (my $test_suite = $test_suites->next) {
        $params{test_suite} = $test_suite;
    }

    my $error_message = OpenQA::JobSettings::generate_settings(\%params);
    return {error_message => $error_message, settings_result => \%settings};
}

1;
