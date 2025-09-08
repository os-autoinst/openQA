# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::ScheduledProducts;

## no critic (OpenQA::RedundantStrictWarning)
use Mojo::Base 'DBIx::Class::Core', -signatures;

use Mojo::Base -base, -signatures;
use DBIx::Class::Timestamps 'now';
use Exporter 'import';
use File::Basename;
use Feature::Compat::Try;
use OpenQA::App;
use OpenQA::Log qw(log_debug log_warning log_error);
use OpenQA::Utils;
use OpenQA::JobSettings;
use OpenQA::Jobs::Constants;
use OpenQA::JobDependencies::Constants;
use OpenQA::Scheduler::Client;
use OpenQA::VcsProvider;
use Mojo::JSON qw(encode_json decode_json);
use OpenQA::YAML 'load_yaml';
use Carp;

use constant {
    ADDED => 'added',    # no jobs have been created yet
    SCHEDULING => 'scheduling',    # jobs are being created
    SCHEDULED => 'scheduled',    # all jobs have been created
    CANCELLING => 'cancelling',    # jobs are being cancelled (so far only possible as reaction to webhook event)
    CANCELLED => 'cancelled',    # all jobs have been cancelled (so far only possible as reaction to webhook event)
};

__PACKAGE__->table('scheduled_products');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'bigint',
        is_auto_increment => 1,
    },
    distri => {
        data_type => 'text',
        default_value => '',
    },
    version => {
        data_type => 'text',
        default_value => '',
    },
    flavor => {
        data_type => 'text',
        default_value => '',
    },
    arch => {
        data_type => 'text',
        default_value => '',
    },
    build => {
        data_type => 'text',
        default_value => '',
    },
    iso => {
        data_type => 'text',
        default_value => '',
    },
    status => {
        data_type => 'text',
        default_value => ADDED,
    },
    settings => {
        data_type => 'jsonb',
    },
    results => {
        data_type => 'jsonb',
        is_nullable => 1,
    },
    user_id => {
        data_type => 'bigint',
        is_nullable => 1,
        is_foreign_key => 1,
    },
    gru_task_id => {
        data_type => 'bigint',
        is_nullable => 1,
        is_foreign_key => 1,
    },
    minion_job_id => {
        data_type => 'bigint',
        is_nullable => 1,
    },
    webhook_id => {
        data_type => 'text',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    triggered_by => 'OpenQA::Schema::Result::Users',
    'user_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->belongs_to(
    gru_task => 'OpenQA::Schema::Result::GruTasks',
    'gru_task_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->has_many(jobs => 'OpenQA::Schema::Result::Jobs', 'scheduled_product_id');
__PACKAGE__->inflate_column(
    settings => {
        inflate => sub { decode_json(shift) },
        deflate => sub { encode_json(shift) },
    });
__PACKAGE__->inflate_column(
    results => {
        inflate => sub { decode_json(shift) },
        deflate => sub { encode_json(shift) },
    });

our @EXPORT = qw(ADDED SCHEDULING SCHEDULED CANCELLING CANCELLED);

sub sqlt_deploy_hook ($self, $sqlt_table, @) {
    $sqlt_table->add_index(name => 'scheduled_products_idx_webhook_id', fields => ['webhook_id']);
}

sub get_setting ($self, $key) { ($self->{_settings} //= $self->settings)->{$key} }

sub update_setting ($self, $key, $value) {
    my $settings = $self->{_settings} //= $self->settings;
    $settings->{$key} = $value;
    $self->update({settings => $settings});
}

sub discard_changes ($self, @args) { undef $self->{_settings}; $self->SUPER::discard_changes(@args) }

sub to_string {
    my ($self) = @_;
    return join('-', grep { $_ ne '' } ($self->distri, $self->version, $self->flavor, $self->arch, $self->build));
}

sub to_hash {
    my ($self, %args) = @_;
    my %result;

    # add all columns
    for my $column ($self->result_source->columns) {
        $result{$column} = $self->get_column($column);
    }

    # decode JSON columns
    for my $column (qw(results settings)) {
        if (my $encoded_json = $result{$column}) {
            $result{$column} = decode_json($encoded_json);
        }
    }

    # add job IDs
    if ($args{include_job_ids}) {
        $result{job_ids} = [map { $_->id } $self->jobs->all];
    }

    return \%result;
}

=over 4

=item _update_status_if()

Updates the status of the scheduled product if the specified conditions match. This is done in an
atomic way. Returns whether the status has been updated.

This function is used to update the status. It ensures that the first status update "wins" and the
"loser" can "back off". This is important to have well-defined behavior despite the race between
setting SCHEDULING and CANCELLING. If CANCELLING wins the scheduled product is not scheduled at all
and simply cancelled. If SCHEDULING wins the product is scheduled normally and `set_done` will
trigger the cancellation after that. To do this, `set_done` needs to check whether the status is
CANCELLING. This means there is another race between setting CANCELLING and the the invocation of
`set_done`. If CANCELLING can be set before `set_done` sets the status `set_done` wins and performs
the cancellation. If `set_done` wins then `cancel` will handle the cancellation directly after all.

=back

=cut

sub _update_status_if ($self, $status, @conds) {
    my $rs = ($self->{_rs} //= $self->result_source->schema->resultset('ScheduledProducts'));
    return $rs->search({id => $self->id, @conds})->update({status => $status}) != 0;
}

=over 4

=item schedule_iso()

Schedule jobs for a given ISO. Starts by downloading needed assets and cancelling obsolete jobs
(unless _NO_OBSOLOLETE was set), and then attempts to start the jobs from the job settings received
from B<_generate_jobs()>. Returns a list of job ids from the jobs that were successfully scheduled
and a list of failure reason for the jobs that could not be scheduled. Internal function, not
exported - but called by B<create()>.

=item $guard

Expects an C<OpenQA::Task::SignalGuard> object. If the related Minion job is aborting after the database
transaction has completed, a restart of the Minion job is prevented so jobs aren't created twice.

=back

=cut

sub schedule_iso ($self, $args, $guard) {
    # update status to SCHEDULING or just return if the job was updated otherwise
    return undef unless $self->_update_status_if(SCHEDULING, status => ADDED);
    $self->{_settings} = $args;

    # schedule the ISO
    $self->discard_changes;
    my $result = do {
        try { $self->_schedule_iso($args, $guard) }
        catch ($e) { {error => $e} }
    };
    $self->set_done($result);

    # return result here as it is consumed by the old synchronous ISO post route and added as Minion job result
    return $result;
}

sub set_done ($self, $result) {
    # set the status to be either …
    if ($self->_update_status_if(CANCELLED, status => CANCELLING)) {
        $self->update({results => $result});
        $self->cancel;    # … CANCELLED if meanwhile CANCELLING and invoke cancel again (as it backed off)
    }
    else {
        $self->update({status => SCHEDULED, results => $result});    # … SCHEDULED if remained SCHEDULING
        $self->report_status_to_github;
    }
}

# make sure that the DISTRI is lowercase
sub _distri_key ($settings) { lc($settings->{DISTRI}) }

sub _delete_prefixed_args_storing_info_about_product_itself ($args) {
    for my $arg (keys %$args) {
        delete $args->{$arg} if substr($arg, 0, 2) eq '__';
    }
}

sub _log_wrong_parents ($self, $parent, $cluster_parents, $failed_job_info) {
    my $job_id = $cluster_parents->{$parent};
    return undef if $job_id eq 'depended';
    my $error_msg = "$parent has no child, check its machine placed or dependency setting typos";
    log_warning($error_msg);
    push @$failed_job_info, {job_id => $job_id, error_messages => [$error_msg]};
}

sub _create_jobs_in_database ($self, $jobs, $failed_job_info, $skip_chained_deps, $include_children,
    $successful_job_ids, $minion_ids = undef)
{
    my $schema = $self->result_source->schema;
    my $jobs_resultset = $schema->resultset('Jobs');
    my @created_jobs;
    my %tmp_downloads;
    my %clones;

    # remember ids of created parents
    my %job_ids_by_test_machine;    # key: "TEST@MACHINE", value: "array of job ids"

    for my $settings (@{$jobs || []}) {
        # create a new job with these parameters and count if successful, do not send job notifies yet
        $schema->svp_begin('try_create_job_from_settings');
        try {
            # Any setting name ending in _URL is special: it tells us to download
            # the file at that URL before running the job
            my $download_list = create_downloads_list($settings);
            create_git_clone_list($settings, \%clones);
            my $job = $jobs_resultset->create_from_settings($settings, $self->id);
            push @created_jobs, $job;
            my $j_id = $job->id;
            $job_ids_by_test_machine{_job_ref($settings)} //= [];
            push @{$job_ids_by_test_machine{_job_ref($settings)}}, $j_id;
            $self->_create_download_lists(\%tmp_downloads, $download_list, $j_id);
            $schema->svp_release('try_create_job_from_settings');
        }
        catch ($e) {
            $schema->svp_rollback('try_create_job_from_settings');
            die $e if $schema->is_deadlock($e);
            push @$failed_job_info, {job_name => $settings->{TEST}, error_message => $e};
        }
    }

    # keep track of ...
    my %created_jobs;    # ... for cycle detection
    my %cluster_parents;    # ... for checking wrong parents

    # jobs are created, now recreate dependencies and extract ids
    for my $job (@created_jobs) {
        my $error_messages
          = $self->_create_dependencies_for_job($job, \%job_ids_by_test_machine, \%created_jobs, \%cluster_parents,
            $skip_chained_deps, $include_children);
        if (!@$error_messages) {
            push @$successful_job_ids, $job->id;
        }
        else {
            push @$failed_job_info, {job_id => $job->id, error_messages => $error_messages};
        }
    }

    $self->_log_wrong_parents($_, \%cluster_parents, $failed_job_info) for sort keys %cluster_parents;
    $_->calculate_blocked_by for @created_jobs;
    my %downloads = map {
        $_ => [
            [keys %{$tmp_downloads{$_}->{destination}}], $tmp_downloads{$_}->{do_extract},
            $tmp_downloads{$_}->{blocked_job_id}]
    } keys %tmp_downloads;
    my $gru = OpenQA::App->singleton->gru;
    $gru->enqueue_download_jobs(\%downloads, $minion_ids);
    $gru->enqueue_git_clones(\%clones, $successful_job_ids, $minion_ids) if keys %clones;
}

=over 4

=item _schedule_iso()

Internal function to actually schedule the ISO, see schedule_iso().

=back

=cut

sub _schedule_iso ($self, $args, $guard) {
    my @notes;
    my $schema = $self->result_source->schema;
    my $user_id = $self->user_id;

    # register assets posted here right away, in case no job templates produce jobs
    my $assets = $schema->resultset('Assets');
    for my $asset (values %{parse_assets_from_settings($args)}) {
        my ($name, $type) = ($asset->{name}, $asset->{type});
        return {error => 'Asset type and name must not be empty.'} unless $name && $type;
        return {error => "Failed to register asset $name."}
          unless $assets->register($type, $name, {missing_ok => 1, refresh_size => 1});
    }

    # read arguments for deprioritization and obsoleten
    my $deprioritize = delete $args->{_DEPRIORITIZEBUILD} // 0;
    my $deprioritize_limit = delete $args->{_DEPRIORITIZE_LIMIT};
    my $obsolete = delete $args->{_OBSOLETE} // 0;
    my $onlysame = delete $args->{_ONLY_OBSOLETE_SAME_BUILD} // 0;
    my $skip_chained_deps = delete $args->{_SKIP_CHAINED_DEPS} // 0;
    my $include_children = delete $args->{_INCLUDE_CHILDREN} // 0;
    my $force = delete $args->{_FORCE_DEPRIORITIZEBUILD};
    $force = delete $args->{_FORCE_OBSOLETE} || $force;
    if (($deprioritize || $obsolete) && $args->{TEST} && !$force) {
        return {error => 'One must not specify TEST and _DEPRIORITIZEBUILD=1/_OBSOLETE=1 at the same time as it is'
              . ' likely not intended to deprioritize the whole build when scheduling a single scenario.'
        };
    }

    _delete_prefixed_args_storing_info_about_product_itself $args;

    my $result;
    my $yaml = delete $args->{SCENARIO_DEFINITIONS_YAML};
    my $yaml_file = delete $args->{SCENARIO_DEFINITIONS_YAML_FILE};
    if (defined $yaml) {
        $result = $self->_schedule_from_yaml($args, $skip_chained_deps, $include_children, string => $yaml);
    }
    elsif (defined $yaml_file) {
        $result = $self->_schedule_from_yaml($args, $skip_chained_deps, $include_children, file => $yaml_file);
    }
    else {
        $result = $self->_generate_jobs($args, \@notes, $skip_chained_deps, $include_children);
    }
    return {error => $result->{error_message}, error_code => $result->{error_code} // 400}
      if defined $result->{error_message};
    my $jobs = $result->{settings_result};
    # take some attributes from the first job to guess what old jobs to cancel
    # note: We should have distri object that decides which attributes are relevant here.
    if (($obsolete || $deprioritize) && $jobs && $jobs->[0] && $jobs->[0]->{BUILD}) {
        my $build = $jobs->[0]->{BUILD};
        log_debug("Triggering new iso with build \'$build\', obsolete: $obsolete, deprioritize: $deprioritize");
        my %cond;
        my @attrs = qw(DISTRI VERSION FLAVOR ARCH);
        push @attrs, 'BUILD' if ($onlysame);
        for my $k (@attrs) {
            next unless $jobs->[0]->{$k};
            $cond{$k} = $jobs->[0]->{$k};
        }
        if (keys %cond) {
            # Prefer new build jobs over old ones either by cancelling old
            # ones or deprioritizing them (up to a limit)
            try {
                OpenQA::Events->singleton->emit_event(
                    'openqa_iso_cancel',
                    data => {scheduled_product_id => $self->id},
                    user_id => $user_id
                );
                $schema->resultset('Jobs')->cancel_by_settings(\%cond, 1, $deprioritize, $deprioritize_limit, $self);
            }
            catch ($e) {
                push(@notes, "Failed to cancel old jobs: $e");
            }
        }
    }

    # define function to create jobs in the database; executed as transaction
    my @successful_job_ids;
    my @failed_job_info;
    my @minion_ids;
    my $gru = OpenQA::App->singleton->gru;

    try {
        $schema->txn_do_retry_on_deadlock(
            sub {
                $self->_create_jobs_in_database($jobs, \@failed_job_info, $skip_chained_deps, $include_children,
                    \@successful_job_ids, \@minion_ids);
            },
            sub {   # this handler is generally covered but tests are unable to reproduce the deadlock 100 % of the time
                $gru->obsolete_minion_jobs(\@minion_ids);    # uncoverable statement
                (@successful_job_ids, @failed_job_info, @minion_ids) = ();    # uncoverable statement
            });
    }
    catch ($e) {
        $gru->obsolete_minion_jobs(\@minion_ids);
        push(@notes, "Transaction failed: $e");
        push(@failed_job_info, map { {job_id => $_, error_messages => [$e]} } @successful_job_ids);
        @successful_job_ids = ();
    }

    $guard->retry(0) if defined($guard);
    # emit events
    for my $succjob (@successful_job_ids) {
        OpenQA::Events->singleton->emit_event('openqa_job_create', data => {id => $succjob}, user_id => $user_id);
    }

    OpenQA::Scheduler::Client->singleton->wakeup;

    my %results = (
        successful_job_ids => \@successful_job_ids,
        failed_job_info => \@failed_job_info,
    );
    $results{notes} = \@notes if (@notes);
    return \%results;
}

=over 4

=item _job_ref()

Return the "job reference" for the specified job settings. It is used internally as a key for the job in various
hash maps. It is also used to refer to a job in dependency specifications.

=back

=cut

sub _job_ref ($job_settings) {
    my ($test, $machine) = ($job_settings->{TEST}, $job_settings->{MACHINE});
    return $machine ? "$test\@$machine" : $test;
}

=over 4

=item _parse_dep_variable()

Parse dependency variable in format like "suite1@64bit,suite2,suite3@uefi"
and return settings arrayref for each entry. Defining the machine explicitly
to make an inter-machine dependency. Otherwise the MACHINE from the settings
is used.

=back

=cut

sub _parse_dep_variable ($value, $job_settings) {
    return unless defined $value;
    return map {
        if ($_ =~ /^(.+)\@([^@]+)$/) { [$1, $2] }
        elsif ($_ =~ /^(.+):([^:]+)$/) { [$1, $2] }    # for backwards compatibility
        else { [$_, $job_settings->{MACHINE}] }
    } split(/\s*,\s*/, $value);
}

sub _chained_parents ($job) {
    [_parse_dep_variable($job->{START_AFTER_TEST}, $job), _parse_dep_variable($job->{START_DIRECTLY_AFTER_TEST}, $job)];
}

sub _parallel_parents ($job) {
    [_parse_dep_variable($job->{PARALLEL_WITH}, $job)];
}

sub _all_parents ($job) { [@{_chained_parents($job)}, @{_parallel_parents($job)}] }

=over 4

=item _sort_dep()

Sort the job list so that children are put after parents. Internal method
used in B<_populate_wanted_jobs_for_parent_dependencies>.

=back

=cut

sub _sort_dep ($list) {
    my (%done, %count, @out);
    ++$count{_job_ref($_)} for @$list;

    for (my $added;; $added = 0) {
        for my $job (@$list) {
            next if $done{$job};
            my $has_parents_to_go_before;
            for my $parent (@{_chained_parents($job)}, @{_parallel_parents($job)}) {
                if ($count{join('@', @$parent)}) {
                    $has_parents_to_go_before = 1;
                    last;
                }
            }
            next if $has_parents_to_go_before;
            push @out, $job;    # no parents go before, we can do this job
            $done{$job} = $added = 1;
            $count{_job_ref($job)}--;
        }
        last unless $added;
    }

    # put cycles and broken dependencies at the end of the list
    for my $job (@$list) {
        push @out, $job unless $done{$job};
    }
    return \@out;
}

=over 4

=item _generate_jobs()

Create jobs for products matching the contents of the DISTRI, VERSION, FLAVOR and ARCH
settings, and returns a sorted list of jobs (parent jobs first) including its settings. Internal
method used in the B<schedule_iso()> method.

=back

=cut

sub _generate_jobs {
    my ($self, $args, $notes, $skip_chained_deps, $include_children) = @_;

    my $ret = [];
    my $schema = $self->result_source->schema;
    my @products = $schema->resultset('Products')->search(
        {
            distri => _distri_key($args),
            version => $args->{VERSION},
            flavor => $args->{FLAVOR},
            arch => $args->{ARCH},
        });

    unless (@products) {
        push(@$notes, 'no products found for version ' . $args->{DISTRI} . ' falling back to "*"');
        @products = $schema->resultset('Products')->search(
            {
                distri => _distri_key($args),
                version => '*',
                flavor => $args->{FLAVOR},
                arch => $args->{ARCH},
            });
    }

    if (!@products) {
        my $error = 'no products found for ' . join('-', map { $args->{$_} } qw(DISTRI FLAVOR ARCH));
        push(@$notes, $error);
        return {error_message => $error, error_code => 200};
    }

    my %wanted;    # jobs specified by $args->{TEST} or $args->{MACHINE} or their parents

    # allow filtering by group
    my $group_id = delete $args->{_GROUP_ID};
    my $group_name = delete $args->{_GROUP};
    if (!defined $group_id && defined $group_name) {
        my $groups = $schema->resultset('JobGroups')->search({name => $group_name});
        my $group = $groups->next or return;
        $group_id = $group->id;
    }

    # allow overriding the priority
    my $priority = delete $args->{_PRIORITY};

    my $error_message;
    for my $product (@products) {
        # find job templates
        my $templates = $product->job_templates;
        if (defined $group_id) {
            $templates = $templates->search({group_id => $group_id});
        }
        my @templates = $templates->all;

        unless (@templates) {
            my $error = 'no templates found for ' . join('-', map { $args->{$_} } qw(DISTRI FLAVOR ARCH));
            push(@$notes, $error);
            return {error_message => $error, error_code => 404};
        }
        for my $job_template (@templates) {
            # compose settings from product, machine, testsuite and job template itself
           # note: That order also defines the precedence from lowest to highest. The only exception is the WORKER_CLASS
            #       variable where all occurrences are merged.
            my %settings;
            my %params = (
                settings => \%settings,
                input_args => $args,
                product => $product,
                machine => $job_template->machine,
                test_suite => $job_template->test_suite,
                job_template => $job_template,
            );
            my $error = OpenQA::JobSettings::generate_settings(\%params);
            $error_message .= $error if defined $error;

            $settings{_PRIORITY} = $priority // $job_template->prio;
            $settings{GROUP_ID} = $job_template->group_id;

            _populate_wanted_jobs_for_test_arg($args, \%settings, \%wanted);
            push @$ret, \%settings;
        }
    }
    $ret = _populate_wanted_jobs_for_parent_dependencies($ret, \%wanted, $skip_chained_deps, $include_children);
    return {error_message => $error_message, settings_result => $ret};
}

=over 4

=item _create_dependencies_for_job()

Create job dependencies for tasks with settings START_AFTER_TEST or PARALLEL_WITH
defined. Internal method used by the B<_schedule_iso()> method.

=back

=cut

sub _create_dependencies_for_job ($self, $job, $job_ids_mapping, $created_jobs, $cluster_parents, $skip_chained_deps,
    $include_children)
{
    my @error_messages;
    my $settings = $job->settings_hash;
    my @deps = ([PARALLEL_WITH => PARALLEL]);
    push @deps, [START_AFTER_TEST => CHAINED], [START_DIRECTLY_AFTER_TEST => DIRECTLY_CHAINED]
      if !$skip_chained_deps || $include_children;
    for my $dependency (@deps) {
        my ($depname, $deptype) = @$dependency;
        next unless defined(my $depvalue = $settings->{$depname});
        my $might_be_skipped = $skip_chained_deps && $deptype != PARALLEL;
        for my $testsuite (_parse_dep_variable($depvalue, $settings)) {
            my ($test, $machine) = @$testsuite;
            my $key = "$test\@$machine";

            for my $parent_job (keys %$job_ids_mapping) {
                my @parents = split(/@/, $parent_job);
                $cluster_parents->{$parent_job} = $job_ids_mapping->{$parent_job}
                  if (!exists $cluster_parents->{$parent_job} && $test eq $parents[0]);
            }

            if (my $parents = $job_ids_mapping->{$key}) {
                $self->_create_dependencies_for_parents($job, $created_jobs, $deptype, [@$parents]);
                $cluster_parents->{$key} = 'depended';
            }
            elsif (!$might_be_skipped) {
                my $error_msg = "$depname=$key not found - check for dependency typos and dependency cycles";
                push @error_messages, $error_msg;
            }
        }
    }
    return \@error_messages;
}

=over 4

=item _check_for_cycle()

Makes sure the job dependencies do not create cycles

=back

=cut

sub _check_for_cycle ($child, $parent, $jobs) {
    $jobs->{$parent} = $child;
    return unless my $job = $jobs->{$child};
    die 'CYCLE' if $job == $parent;
    # go deeper into the graph
    _check_for_cycle($job, $parent, $jobs);
}

=over 4

=item _create_dependencies_for_parents()

Internal method used by the B<job_create_dependencies()> method

=back

=cut

sub _create_dependencies_for_parents ($self, $job, $created_jobs, $deptype, $parents) {
    my $schema = $self->result_source->schema;
    my $job_dependencies = $schema->resultset('JobDependencies');
    my $job_settings = $schema->resultset('JobSettings');
    my $worker_classes;
    for my $parent (@$parents) {
        try {
            _check_for_cycle($job->id, $parent, $created_jobs);
        }
        catch ($e) {
            die 'There is a cycle in the dependencies of ' . $job->TEST;
        }
        if ($deptype eq OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED) {
            $worker_classes //= join(',', @{$job_settings->all_values_sorted($job->id, 'WORKER_CLASS')});
            my $parent_worker_classes = join(',', @{$job_settings->all_values_sorted($parent, 'WORKER_CLASS')});
            if ($worker_classes ne $parent_worker_classes) {
                my $test_name = $job->TEST;
                die "Worker class of $test_name ($worker_classes) does not match the worker class of its "
                  . "directly chained parent ($parent_worker_classes)";
            }
        }
        $job_dependencies->create({child_job_id => $job->id, parent_job_id => $parent, dependency => $deptype});
    }
}

=over 4

=item _create_download_lists()

Internal method used by the B<_schedule_iso()> method

=back

=cut

sub _create_download_lists {
    my ($self, $tmp_downloads, $download_list, $job_id) = @_;
    foreach my $url (keys %$download_list) {
        my $download_parameters = $download_list->{$url};
        my $destination_path = $download_parameters->[0];

        # caveat: The extraction parameter is currently not processed per destination.
        # If multiple destinations for the same download have a different 'do_extract' parameter the first one will win.
        my $download_info = $tmp_downloads->{$url};
        unless ($download_info) {
            $tmp_downloads->{$url} = {
                destination => {$destination_path => 1},
                do_extract => $download_parameters->[1],
                blocked_job_id => [$job_id]};
            next;
        }
        push @{$download_info->{blocked_job_id}}, $job_id;
        $download_info->{destination}->{$destination_path} = 1
          unless ($download_info->{destination}->{$destination_path});
    }
}

sub _schedule_from_yaml ($self, $args, $skip_chained_deps, $include_children, @load_yaml_args) {
    my $data;
    try { $data = load_yaml(@load_yaml_args) }
    catch ($e) { return {error_message => "Unable to load YAML: $e"} }

    my $app = OpenQA::App->singleton;
    my $validation_errors = $app->validate_yaml($data, 'JobScenarios-01.yaml', $app->log->level eq 'debug');
    return {error_message => "YAML validation failed:\n" . join("\n", @$validation_errors)} if @$validation_errors;

    my $products = $data->{products};
    my $machines = $data->{machines} // {};
    my $job_templates = $data->{job_templates};
    my ($error_msg, %wanted, @job_templates);
    for my $key (sort keys %$job_templates) {
        my $job_template = $job_templates->{$key};
        my $settings = $job_template->{settings} // {};
        $settings->{TEST} = $key;
        my @worker_class;
        push @worker_class, $settings->{WORKER_CLASS} if $settings->{WORKER_CLASS};

        # add settings from product (or skip if there is no such product) if a product is specified
        if (my $product_name = $job_template->{product}) {
            next unless defined $products;
            next unless my $product = $products->{$product_name};
            next
              if ( $product->{distri} ne _distri_key($args)
                || $product->{flavor} ne $args->{FLAVOR}
                || ($product->{version} ne '*' && $product->{version} ne $args->{VERSION})
                || $product->{arch} ne $args->{ARCH});
            my $product_settings = $product->{settings} // {};
            _merge_settings_uppercase($product, $settings, 'settings');
            _merge_settings_and_worker_classes($product_settings, $settings, \@worker_class);
        }

        # add settings from machine if specified
        if (my $machine = $job_template->{machine}) {
            $settings->{MACHINE} = $machine;
            if (my $mach = $machines->{$machine}) {
                my $machine_settings = $mach->{settings} // {};
                _merge_settings_and_worker_classes($machine_settings, $settings, \@worker_class);
                $settings->{BACKEND} = $mach->{backend} if $mach->{backend};
                $settings->{_PRIORITY} = $mach->{priority} // DEFAULT_JOB_PRIORITY;
            }
        }

        # set priority of job if specified
        if (my $priority = $job_template->{priority}) {
            $settings->{_PRIORITY} = $priority;
        }

        # handle further settings
        $settings->{WORKER_CLASS} = join ',', sort @worker_class if @worker_class > 0;
        _merge_settings_uppercase($args, $settings, 'TEST');
        $settings->{DISTRI} = _distri_key($settings) if $settings->{DISTRI};
        OpenQA::JobSettings::parse_url_settings($settings);
        OpenQA::JobSettings::handle_plus_in_settings($settings);
        my $error = OpenQA::JobSettings::expand_placeholders($settings);
        $error_msg .= $error if defined $error;
        _populate_wanted_jobs_for_test_arg($args, $settings, \%wanted);
        push @job_templates, $settings;
    }

    return {
        settings_result => _populate_wanted_jobs_for_parent_dependencies(
            \@job_templates, \%wanted, $skip_chained_deps, $include_children
        ),
        error_message => $error_msg,
    };
}

sub _merge_settings_and_worker_classes ($source_settings, $destination_settings, $worker_classes) {
    for my $s_key (keys %$source_settings) {
        if ($s_key eq 'WORKER_CLASS') {    # merge WORKER_CLASS from different $source_settings later
            push @$worker_classes, $source_settings->{WORKER_CLASS};
            next;
        }
        $destination_settings->{$s_key} = $source_settings->{$s_key};
    }
}

sub _merge_settings_uppercase ($source_settings, $destination_settings, $exception) {
    for (keys %$source_settings) {
        $destination_settings->{uc $_} = $source_settings->{$_} if $_ ne $exception;
    }
}

sub _populate_wanted_jobs_for_test_arg ($args, $settings, $wanted) {
    return undef if $args->{MACHINE} && $args->{MACHINE} ne $settings->{MACHINE};    # skip if machine does not match
    my @tests = $args->{TEST} ? split(/\s*,\s*/, $args->{TEST}) : ();    # allow multiple, comma-separated TEST values
    return $wanted->{_job_ref($settings)} = 1 unless @tests;
    my $settings_test = $settings->{TEST};
    for my $test (@tests) {
        if ($test eq $settings_test) {
            $wanted->{_job_ref($settings)} = 1;
            last;
        }
    }
}

sub _is_any_parent_wanted ($jobs, $parents, $wanted_list, $visited = {}) {
    for my $parent (@$parents) {
        my $parent_job_ref = join('@', @$parent);
        next if $visited->{$parent_job_ref}++;    # prevent deep recursion if there are dependency cycles
        for my $job (@$jobs) {
            my $job_ref = _job_ref($job);
            next unless $job_ref eq $parent_job_ref;
            return 1 if $wanted_list->{$job_ref};
            return 1 if _is_any_parent_wanted($jobs, _all_parents($job), $wanted_list, $visited);
        }
    }
    return 0;
}

sub _populate_wanted_jobs_for_parent_dependencies ($jobs, $wanted, $skip_chained_deps, $include_children) {
    # sort $jobs so parents are first
    $jobs = _sort_dep($jobs);

    # iterate in reverse order to go though children first and being able to easily delete from $jobs
    for (my $i = $#{$jobs}; $i >= 0; --$i) {
        my $job = $jobs->[$i];

        # parse relevant parents from job settings
        my $chained_parents = !$skip_chained_deps || $include_children ? _chained_parents($job) : [];
        my $parallel_parents = _parallel_parents($job);
        my $all_parents = [@$chained_parents, @$parallel_parents];
        my $wanted_parents = $skip_chained_deps ? $parallel_parents : $all_parents;

        # delete unwanted jobs unless the parent is wanted and we include children
        my $unwanted = !$wanted->{_job_ref($job)};
        splice @$jobs, $i, 1 and next
          if $unwanted && (!$include_children || !_is_any_parent_wanted($jobs, $all_parents, $wanted));

        # add parents to wanted list
        for my $parent (@$wanted_parents) {
            my $parent_job_ref = join('@', @$parent);
            for my $job (@$jobs) {
                my $job_ref = _job_ref($job);
                $wanted->{$job_ref} = 1 if $job_ref eq $parent_job_ref;
            }
        }
    }
    return $jobs;
}

sub enqueue_minion_job ($self, $params) {
    my $id = $self->id;
    my %minion_job_args = (scheduled_product_id => $id, scheduling_params => $params);
    my $gru = OpenQA::App->singleton->gru;
    my $ids = $gru->enqueue(schedule_iso => \%minion_job_args, {priority => 10});
    my %res = (gru_task_id => $ids->{gru_id}, minion_job_id => $ids->{minion_id});
    $self->update(\%res);
    $res{scheduled_product_id} = $id;
    return \%res;
}

# returns the "state" to be passed to GitHub's "statuses"-API considering the state/result of associated jobs
sub state_for_ci_status ($self) {
    return 'pending' if $self->status eq ADDED;
    my @jobs = $self->jobs;
    # consider no jobs being scheduled a failure
    return ('failure', 'No openQA jobs have been scheduled') unless my $total = @jobs;
    my ($pending, $failed);
    for my $job (@jobs) {
        my $latest_job = $job->latest_job;    # only consider the latest job in a chain of clones
        $pending += 1 and next unless $latest_job->is_final;
        $failed += 1 unless $latest_job->is_ok;
    }
    return ('pending', $pending == 1 ? 'is pending' : 'are pending', $pending, $total) if $pending;
    return ('failure', $failed == 1 ? 'has failed' : 'have failed', $failed, $total) if $failed;
    return ('success', $total == 1 ? 'has passed' : 'have passed', $total, $total);
}

sub _format_check_description ($verb, $count, $total) {
    return undef unless defined $verb;    # use default description
    return $verb unless $total;    # just use $verb as-is without $total; then $verb is then the whole phrase
    return "$count of $total openQA jobs $verb" if $total != $count;
    return "The openQA job $verb" if $total == 1;
    return "All $total openQA jobs $verb";
}

sub report_status_to_github ($self, $callback = undef) {
    my $id = $self->id;
    my $settings = $self->{_settings} // $self->settings;
    return undef unless my $github_statuses_url = $settings->{GITHUB_STATUSES_URL};
    my ($state, $verb, $count, $total) = $self->state_for_ci_status;
    return undef unless $state;
    my $vcs = OpenQA::VcsProvider->new(app => OpenQA::App->singleton);
    my $base_url = $settings->{CI_TARGET_URL};
    my %params = (state => $state, description => _format_check_description($verb, $count, $total));
    $vcs->report_status_to_github($github_statuses_url, \%params, $id, $base_url, $callback);
}

sub cancel ($self, $reason = undef) {
    # store the cancellation reason (if there is one) as setting
    $self->update_setting(_CANCELLATION_REASON => $reason) if $reason;

    # update status to CANCELLING
    if (!$self->_update_status_if(CANCELLING, -not => {status => SCHEDULING})) {
       # the scheduled product is SCHEDULING; set it nevertheless to CANCELLING but back off from cancelling immediately
        # unless it is not SCHEDULING anymore after all
        return 0 if $self->_update_status_if(CANCELLING, status => SCHEDULING);
    }

    # do the actual cancellation
    my $job_reason = 'scheduled product cancelled';
    $reason = $self->get_setting('_CANCELLATION_REASON') unless $reason;
    $job_reason .= ": $reason" if $reason;
    my $count = 0;
    $count += $_->cancel_whole_clone_chain(USER_CANCELLED, $job_reason) for $self->jobs;
    $self->update({status => CANCELLED});
    return $count;
}

1;
