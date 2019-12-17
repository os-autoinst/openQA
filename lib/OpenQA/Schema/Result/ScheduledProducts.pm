# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Schema::Result::ScheduledProducts;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use DBIx::Class::Timestamps 'now';
use File::Basename;
use Try::Tiny;
use OpenQA::Utils;
use OpenQA::ExpandPlaceholder;
use OpenQA::JobDependencies::Constants;
use OpenQA::Scheduler::Client;
use Mojo::JSON qw(encode_json decode_json);
use Carp;

use constant {
    ADDED      => 'added',
    SCHEDULING => 'scheduling',
    SCHEDULED  => 'scheduled',
};

__PACKAGE__->table('scheduled_products');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    distri => {
        data_type     => 'text',
        default_value => '',
    },
    version => {
        data_type     => 'text',
        default_value => '',
    },
    flavor => {
        data_type     => 'text',
        default_value => '',
    },
    arch => {
        data_type     => 'text',
        default_value => '',
    },
    build => {
        data_type     => 'text',
        default_value => '',
    },
    iso => {
        data_type     => 'text',
        default_value => '',
    },
    status => {
        data_type     => 'text',
        default_value => ADDED,
    },
    settings => {
        data_type => 'jsonb',
    },
    results => {
        data_type   => 'jsonb',
        is_nullable => 1,
    },
    user_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    gru_task_id => {
        data_type      => 'integer',
        is_nullable    => 1,
        is_foreign_key => 1,
    },
    minion_job_id => {
        data_type   => 'integer',
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

=item schedule_iso()

Schedule jobs for a given ISO. Starts by downloading needed assets and cancelling obsolete jobs
(unless _NO_OBSOLOLETE was set), and then attempts to start the jobs from the job settings received
from B<_generate_jobs()>. Returns a list of job ids from the jobs that were succesfully scheduled
and a list of failure reason for the jobs that could not be scheduled. Internal function, not
exported - but called by B<create()>.

=back

=cut

sub schedule_iso {
    my ($self, $args) = @_;

    # load columns with default_value
    $self->discard_changes;

    # update status
    my $current_status = $self->status;
    if ($current_status ne ADDED) {
        die "refuse calling schedule_iso on product with status $current_status";
    }
    $self->update({status => SCHEDULING});

    # schedule the ISO
    my $result;
    try {
        $result = $self->_schedule_iso($args);
    }
    catch {
        $result = {error => $_};
    };

    # update status
    $self->update(
        {
            status  => SCHEDULED,
            results => $result,
        });

    # return result here as it is consumed by the old synchronous ISO post route and added as Minion job result
    return $result;
}

=over 4

=item _schedule_iso()

Internal function to actually schedule the ISO, see schedule_iso().

=back

=cut

sub _schedule_iso {
    my ($self, $args) = @_;

    my @notes;
    my $gru     = $OpenQA::Utils::app->gru;
    my $schema  = $self->result_source->schema;
    my $user_id = $self->user_id;

    # register assets posted here right away, in case no job templates produce jobs
    my $assets = $schema->resultset('Assets');
    for my $asset (values %{parse_assets_from_settings($args)}) {
        my ($name, $type) = ($asset->{name}, $asset->{type});
        return {error => 'Asset type and name must not be empty.'} unless $name && $type;
        return {error => "Failed to register asset $name."}        unless $assets->register($type, $name, 1);
    }

    # read arguments for deprioritization and obsoleten
    my $deprioritize       = delete $args->{_DEPRIORITIZEBUILD} // 0;
    my $deprioritize_limit = delete $args->{_DEPRIORITIZE_LIMIT};
    my $obsolete           = delete $args->{_OBSOLETE} // 0;
    my $onlysame           = delete $args->{_ONLY_OBSOLETE_SAME_BUILD} // 0;
    my $skip_chained_deps  = delete $args->{_SKIP_CHAINED_DEPS} // 0;

    # Any arg name ending in _URL is special: it tells us to download
    # the file at that URL before running the job
    my $downloads = create_downloads_list($args);
    my $result    = $self->_generate_jobs($args, \@notes, $skip_chained_deps);
    return {error => $result->{error_message}} if defined $result->{error_message};
    my $jobs = $result->{settings_result};

    # take some attributes from the first job to guess what old jobs to cancel
    # note: We should have distri object that decides which attributes are relevant here.
    if (($obsolete || $deprioritize) && $jobs && $jobs->[0] && $jobs->[0]->{BUILD}) {
        my $build = $jobs->[0]->{BUILD};
        OpenQA::Utils::log_debug(
            "Triggering new iso with build \'$build\', obsolete: $obsolete, deprioritize: $deprioritize");
        my %cond;
        my @attrs = qw(DISTRI VERSION FLAVOR ARCH);
        push @attrs, 'BUILD' if ($onlysame);
        for my $k (@attrs) {
            next unless $jobs->[0]->{$k};
            $cond{$k} = $jobs->[0]->{$k};
        }
        if (%cond) {
            # Prefer new build jobs over old ones either by cancelling old
            # ones or deprioritizing them (up to a limit)
            try {
                OpenQA::Events->singleton->emit_event(
                    'openqa_iso_cancel',
                    data    => {scheduled_product_id => $self->id},
                    user_id => $user_id
                );
                $schema->resultset('Jobs')->cancel_by_settings(\%cond, 1, $deprioritize, $deprioritize_limit);
            }
            catch {
                my $error = shift;
                push(@notes, "Failed to cancel old jobs: $error");
            };
        }
    }

    # define function to create jobs in the database; executed as transaction
    my @successful_job_ids;
    my @failed_job_info;
    my $create_jobs_in_database = sub {
        my $jobs_resultset = $schema->resultset('Jobs');
        my @created_jobs;

        # remember ids of created parents
        my %testsuite_ids;    # key: "suite", value: {key: "machine", value: "array of job ids"}

        for my $settings (@{$jobs || []}) {
            my $prio = delete $settings->{PRIO};
            $settings->{_GROUP_ID} = delete $settings->{GROUP_ID};

            # create a new job with these parameters and count if successful, do not send job notifies yet
            try {
                my $job = $jobs_resultset->create_from_settings($settings, $self->id);
                push @created_jobs, $job;

                $testsuite_ids{$settings->{TEST_SUITE_NAME}}->{$settings->{MACHINE}} //= [];
                push @{$testsuite_ids{$settings->{TEST_SUITE_NAME}}->{$settings->{MACHINE}}}, $job->id;

                # set prio if defined explicitely (otherwise default prio is used)
                $job->update({priority => $prio}) if (defined($prio));
            }
            catch {
                push(@failed_job_info, {job_name => $settings->{TEST}, error_message => $_});
            }
        }

        # keep track of ...
        my %created_jobs;       # ... for cycle detection
        my %cluster_parents;    # ... for checking wrong parents

        # jobs are created, now recreate dependencies and extract ids
        for my $job (@created_jobs) {
            my $error_messages
              = $self->_create_dependencies_for_job($job, \%testsuite_ids, \%created_jobs, \%cluster_parents,
                $skip_chained_deps);
            if (!@$error_messages) {
                push(@successful_job_ids, $job->id);
            }
            else {
                push(
                    @failed_job_info,
                    {
                        job_id         => $job->id,
                        error_messages => $error_messages
                    });
            }
        }

        # log wrong parents
        for my $parent_test_machine (sort keys %cluster_parents) {
            my $job_id = $cluster_parents{$parent_test_machine};
            next if $job_id eq 'depended';
            my $error_msg = "$parent_test_machine has no child, check its machine placed or dependency setting typos";
            OpenQA::Utils::log_warning($error_msg);
            push(
                @failed_job_info,
                {
                    job_id         => $job_id,
                    error_messages => [$error_msg]});
        }

        # now calculate blocked_by state
        for my $job (@created_jobs) {
            $job->calculate_blocked_by;
        }
        $gru->enqueue_download_jobs($downloads, \@successful_job_ids);
    };

    try {
        $schema->txn_do($create_jobs_in_database);
    }
    catch {
        my $error = shift;
        push(@notes,           "Transaction failed: $error");
        push(@failed_job_info, map { {job_id => $_, error_messages => [$error]} } @successful_job_ids);
        @successful_job_ids = ();
    };

    # enqueue cleanup task
    $gru->enqueue_limit_assets();
    $gru->enqueue(limit_results_and_logs => [], {priority => 5, ttl => 172800, limit => 1});

    # emit events
    for my $succjob (@successful_job_ids) {
        OpenQA::Events->singleton->emit_event('openqa_job_create', data => {id => $succjob}, user_id => $user_id);
    }

    OpenQA::Scheduler::Client->singleton->wakeup;

    my %results = (
        successful_job_ids => \@successful_job_ids,
        failed_job_info    => \@failed_job_info,
    );
    $results{notes} = \@notes if (@notes);
    return \%results;
}

=over 4

=item _settings_key()

Return settings key for given job settings. Internal method.

=back

=cut

sub _settings_key {
    my ($settings) = @_;
    return "$settings->{TEST}\@$settings->{MACHINE}";
}

=over 4

=item _parse_dep_variable()

Parse dependency variable in format like "suite1@64bit,suite2,suite3@uefi"
and return settings arrayref for each entry. Defining the machine explicitly
to make an inter-machine dependency. Otherwise the MACHINE from the settings
is used.

=back

=cut

sub _parse_dep_variable {
    my ($value, $settings) = @_;

    return unless defined $value;
    return map {
        if ($_ =~ /^(.+)\@([^@]+)$/) {
            [$1, $2];
        }
        elsif ($_ =~ /^(.+):([^:]+)$/) {
            [$1, $2];    # for backwards compatibility
        }
        else {
            [$_, $settings->{MACHINE}];
        }
    } split(/\s*,\s*/, $value);
}

=over 4

=item _sort_dep()

Sort the job list so that children are put after parents. Internal method
used in B<_generate_jobs>.

=back

=cut

sub _sort_dep {
    my ($list, $skip_chained_deps) = @_;

    my %done;
    my %count;
    my @out;

    for my $job (@$list) {
        $count{_settings_key($job)} //= 0;
        $count{_settings_key($job)}++;
    }

    my $added;
    do {
        $added = 0;
        for my $job (@$list) {
            next if $done{$job};
            my @parents;
            push @parents, _parse_dep_variable($job->{START_AFTER_TEST}, $job),
              _parse_dep_variable($job->{START_DIRECTLY_AFTER_TEST}, $job),
              _parse_dep_variable($job->{PARALLEL_WITH},             $job);

            my $c = 0;    # number of parents that must go to @out before this job
            foreach my $parent (@parents) {
                my $parent_test_machine = join('@', @$parent);
                $c += $count{$parent_test_machine} if defined $count{$parent_test_machine};
            }

            if ($c == 0) {    # no parents, we can do this job
                push @out, $job;
                $done{$job} = 1;
                $count{_settings_key($job)}--;
                $added = 1;
            }
        }
    } while ($added);

    #cycles, broken dep, put at the end of the list
    for my $job (@$list) {
        next if $done{$job};
        push @out, $job;
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
    my ($self, $args, $notes, $skip_chained_deps) = @_;

    my $ret      = [];
    my $schema   = $self->result_source->schema;
    my @products = $schema->resultset('Products')->search(
        {
            distri  => lc($args->{DISTRI}),
            version => $args->{VERSION},
            flavor  => $args->{FLAVOR},
            arch    => $args->{ARCH},
        });

    unless (@products) {
        push(@$notes, 'no products found, retrying version wildcard');
        @products = $schema->resultset('Products')->search(
            {
                distri  => lc($args->{DISTRI}),
                version => '*',
                flavor  => $args->{FLAVOR},
                arch    => $args->{ARCH},
            });
    }

    if (!@products) {
        carp "no products found for " . join('-', map { $args->{$_} } qw(DISTRI VERSION FLAVOR ARCH));
    }

    my %wanted;    # jobs specified by $args->{TEST} or $args->{MACHINE} or their parents

    # Allow a comma separated list of tests here; whitespaces allowed
    my @tests = $args->{TEST} ? split(/\s*,\s*/, $args->{TEST}) : ();

    # allow filtering by group
    my $group_id   = delete $args->{_GROUP_ID};
    my $group_name = delete $args->{_GROUP};
    if (!defined $group_id && defined $group_name) {
        my $groups = $schema->resultset('JobGroups')->search({name => $group_name});
        my $group  = $groups->next or return;
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
            carp "no templates found for " . join('-', map { $args->{$_} } qw(DISTRI VERSION FLAVOR ARCH));
        }
        for my $job_template (@templates) {
           # compose settings from product, machine, testsuite and job template itself
           # note: That order also defines the precedence from lowest to highest. The only exception is the WORKER_CLASS
           #       variable where all occurrences are merged.
            my %settings;
            my @worker_classes;
            for my $entity ($product, $job_template->machine, $job_template->test_suite, $job_template) {
                my %settings_of_entity = map { $_->key => $_->value } $entity->settings;
                if (my $worker_class = delete $settings_of_entity{WORKER_CLASS}) {
                    push(@worker_classes, $worker_class);
                }
                @settings{keys %settings_of_entity} = values %settings_of_entity;
            }

            # add properties from dedicated database columns to settings
            $settings{TEST}              = $job_template->name || $job_template->test_suite->name;
            $settings{MACHINE}           = $job_template->machine->name;
            $settings{BACKEND}           = $job_template->machine->backend;
            $settings{JOB_TEMPLATE_NAME} = $job_template->name if $job_template->name;
            $settings{TEST_SUITE_NAME}   = $job_template->test_suite->name;

            # merge worker classes
            $settings{WORKER_CLASS} = @worker_classes ? join(',', sort(@worker_classes)) : "qemu_$args->{ARCH}";

            # add upper-case versions of keys
            for my $key (keys %$args) {
                next if $key eq 'TEST' || $key eq 'MACHINE';
                $settings{uc $key} = $args->{$key};
            }

            # make sure that the DISTRI is lowercase
            $settings{DISTRI} = lc($settings{DISTRI});

            $settings{PRIO}     = defined($priority) ? $priority : $job_template->prio;
            $settings{GROUP_ID} = $job_template->group_id;

            # allow some messing with the usual precedence order. If anything
            # sets +VARIABLE, that setting will be used as VARIABLE regardless
            # (so a product or template +VARIABLE beats a post'ed VARIABLE).
            # if *multiple* things set +VARIABLE, whichever comes highest in
            # the usual precedence order wins.
            for (keys %settings) {
                if (substr($_, 0, 1) eq '+') {
                    $settings{substr($_, 1)} = delete $settings{$_};
                }
            }

            # variable expansion
            # replace %NAME% with $settings{NAME}
            my $error = OpenQA::ExpandPlaceholder::expand_placeholders(\%settings);
            $error_message .= $error if defined $error;

            if (!$args->{MACHINE} || $args->{MACHINE} eq $settings{MACHINE}) {
                if (!@tests) {
                    $wanted{_settings_key(\%settings)} = 1;
                }
                else {
                    foreach my $test (@tests) {
                        if ($test eq $settings{TEST} || $test eq $settings{TEST_SUITE_NAME}) {
                            $wanted{_settings_key(\%settings)} = 1;
                            last;
                        }
                    }
                }
            }
            push @$ret, \%settings;
        }
    }

    $ret = _sort_dep($ret);
    # the array is sorted parents first - iterate it backward
    for (my $i = $#{$ret}; $i >= 0; $i--) {
        if ($wanted{_settings_key($ret->[$i])}) {
            # add parents to wanted list
            my @parents;
            push @parents, _parse_dep_variable($ret->[$i]->{START_AFTER_TEST}, $ret->[$i]),
              _parse_dep_variable($ret->[$i]->{START_DIRECTLY_AFTER_TEST}, $ret->[$i])
              unless $skip_chained_deps;
            push @parents, _parse_dep_variable($ret->[$i]->{PARALLEL_WITH}, $ret->[$i]);
            for my $parent (@parents) {
                my $parent_test_machine = join('@', @$parent);
                my @parents_job_template
                  = grep { join('@', $_->{TEST_SUITE_NAME}, $_->{MACHINE}) eq $parent_test_machine } @$ret;
                for my $parent_job_template (@parents_job_template) {
                    $wanted{join('@', $parent_job_template->{TEST}, $parent_job_template->{MACHINE})} = 1;
                }
            }
        }
        else {
            splice @$ret, $i, 1;    # not wanted - delete
        }
    }
    return {error_message => $error_message, settings_result => $ret};
}

=over 4

=item _create_dependencies_for_job()

Create job dependencies for tasks with settings START_AFTER_TEST or PARALLEL_WITH
defined. Internal method used by the B<_schedule_iso()> method.

=back

=cut

sub _create_dependencies_for_job {
    my ($self, $job, $testsuite_mapping, $created_jobs, $cluster_parents, $skip_chained_deps) = @_;

    my @error_messages;
    my $settings     = $job->settings_hash;
    my @dependencies = ([PARALLEL_WITH => OpenQA::JobDependencies::Constants::PARALLEL]);
    push(@dependencies,
        [START_AFTER_TEST          => OpenQA::JobDependencies::Constants::CHAINED],
        [START_DIRECTLY_AFTER_TEST => OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED])
      unless $skip_chained_deps;
    for my $dependency (@dependencies) {
        my ($depname, $deptype) = @$dependency;
        next unless defined $settings->{$depname};
        for my $testsuite (_parse_dep_variable($settings->{$depname}, $settings)) {
            my ($test, $machine) = @$testsuite;
            for my $machine_from_testsuite (keys %{$testsuite_mapping->{$test}}) {
                my $key = "$test\@$machine_from_testsuite";
                if (!exists $cluster_parents->{$key}) {
                    $cluster_parents->{$key} = $testsuite_mapping->{$test}->{$machine_from_testsuite};
                }
            }
            if (!defined $testsuite_mapping->{$test}->{$machine}) {
                my $error_msg = "$depname=$test\@$machine not found - check for dependency typos and dependency cycles";
                push(@error_messages, $error_msg);
            }
            else {
                my @parents = @{$testsuite_mapping->{$test}->{$machine}};
                $self->_create_dependencies_for_parents($job, $created_jobs, $deptype, \@parents);
                $cluster_parents->{"$test\@$machine"} = 'depended';
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

sub _check_for_cycle {
    my ($child, $parent, $jobs) = @_;
    $jobs->{$parent} = $child;
    return unless $jobs->{$child};
    die "CYCLE" if $jobs->{$child} == $parent;
    # go deeper into the graph
    _check_for_cycle($jobs->{$child}, $parent, $jobs);
}

=over 4

=item _create_dependencies_for_parents()

Internal method used by the B<job_create_dependencies()> method

=back

=cut

sub _create_dependencies_for_parents {
    my ($self, $job, $created_jobs, $deptype, $parents) = @_;

    my $schema           = $self->result_source->schema;
    my $job_dependencies = $schema->resultset('JobDependencies');
    my $worker_class;
    for my $parent (@$parents) {
        try {
            _check_for_cycle($job->id, $parent, $created_jobs);
        }
        catch {
            die 'There is a cycle in the dependencies of ' . $job->settings_hash->{TEST};
        };
        if ($deptype eq OpenQA::JobDependencies::Constants::DIRECTLY_CHAINED) {
            unless (defined $worker_class) {
                $worker_class = $job->settings->find({key => 'WORKER_CLASS'});
                $worker_class = $worker_class ? $worker_class->value : '';
            }
            my $parent_worker_class
              = $schema->resultset('JobSettings')->find({job_id => $parent, key => 'WORKER_CLASS'});
            $parent_worker_class = $parent_worker_class ? $parent_worker_class->value : '';
            if ($worker_class ne $parent_worker_class) {
                my $test_name = $job->settings_hash->{TEST};
                die
"Worker class of $test_name ($worker_class) does not match the worker class of its directly chained parent ($parent_worker_class)";
            }
        }
        $job_dependencies->create(
            {
                child_job_id  => $job->id,
                parent_job_id => $parent,
                dependency    => $deptype,
            });
    }
}

1;
