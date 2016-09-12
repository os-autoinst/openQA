# Copyright (C) 2015-2016 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::Schema::Result::Jobs;
use strict;
use warnings;
use base qw/DBIx::Class::Core/;
use Try::Tiny;
use JSON;
use Fcntl;
use DateTime;
use db_helpers;
use OpenQA::Utils qw/log_debug log_warning parse_assets_from_settings/;
use File::Basename qw/basename dirname/;
use File::Path ();
use DBIx::Class::Timestamps qw/now/;

# The state and results constants are duplicated in the Python client:
# if you change them or add any, please also update const.py.

# States
use constant {
    SCHEDULED => 'scheduled',
    RUNNING   => 'running',
    CANCELLED => 'cancelled',
    WAITING   => 'waiting',
    DONE      => 'done',
    UPLOADING => 'uploading',
    #    OBSOLETED => 'obsoleted',
};
use constant STATES => (SCHEDULED, RUNNING, CANCELLED, WAITING, DONE, UPLOADING);
use constant PENDING_STATES => (SCHEDULED, RUNNING, WAITING, UPLOADING);
use constant EXECUTION_STATES => (RUNNING, WAITING, UPLOADING);
use constant FINAL_STATES => (DONE, CANCELLED);

# Results
use constant {
    NONE               => 'none',
    PASSED             => 'passed',
    SOFTFAILED         => 'softfailed',
    FAILED             => 'failed',
    INCOMPLETE         => 'incomplete',            # worker died or reported some problem
    SKIPPED            => 'skipped',               # dependencies failed before starting this job
    OBSOLETED          => 'obsoleted',             # new iso was posted
    PARALLEL_FAILED    => 'parallel_failed',       # parallel job failed, this job can't continue
    PARALLEL_RESTARTED => 'parallel_restarted',    # parallel job was restarted, this job has to be restarted too
    USER_CANCELLED     => 'user_cancelled',        # cancelled by user via job_cancel
    USER_RESTARTED     => 'user_restarted',        # restarted by user via job_restart
};
use constant RESULTS => (NONE, PASSED, SOFTFAILED, FAILED, INCOMPLETE, SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED);
use constant COMPLETE_RESULTS => (PASSED, SOFTFAILED, FAILED);
use constant INCOMPLETE_RESULTS => (INCOMPLETE, SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED);

# scenario keys w/o MACHINE. Add MACHINE when desired, commonly joined on
# other keys with the '@' character
use constant SCENARIO_KEYS => (qw/DISTRI VERSION FLAVOR ARCH TEST/);
use constant SCENARIO_WITH_MACHINE_KEYS => (SCENARIO_KEYS, 'MACHINE');

__PACKAGE__->table('jobs');
__PACKAGE__->load_components(qw/InflateColumn::DateTime FilterColumn Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    slug => {    # to be removed?
        data_type   => 'text',
        is_nullable => 1
    },
    result_dir => {    # this is the directory below testresults
        data_type   => 'text',
        is_nullable => 1
    },
    state => {
        data_type     => 'varchar',
        default_value => SCHEDULED,
    },
    priority => {
        data_type     => 'integer',
        default_value => 50,
    },
    result => {
        data_type     => 'varchar',
        default_value => NONE,
    },
    clone_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1
    },
    retry_avbl => {
        data_type     => 'integer',
        default_value => 3,
    },
    backend => {
        data_type   => 'varchar',
        is_nullable => 1,
    },
    backend_info => {
        # we store free text JSON here - backends might store random data about the job
        data_type   => 'text',
        is_nullable => 1,
    },
    TEST => {
        data_type   => 'text',
        is_nullable => 1
    },
    DISTRI => {
        data_type   => 'text',
        is_nullable => 1
    },
    VERSION => {
        data_type   => 'text',
        is_nullable => 1
    },
    FLAVOR => {
        data_type   => 'text',
        is_nullable => 1
    },
    ARCH => {
        data_type   => 'text',
        is_nullable => 1
    },
    BUILD => {
        data_type   => 'text',
        is_nullable => 1
    },
    MACHINE => {
        data_type   => 'text',
        is_nullable => 1
    },
    group_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1
    },
    t_started => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    t_finished => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;

__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(settings => 'OpenQA::Schema::Result::JobSettings', 'job_id');
__PACKAGE__->has_one(worker => 'OpenQA::Schema::Result::Workers', 'job_id');
__PACKAGE__->belongs_to(clone => 'OpenQA::Schema::Result::Jobs',      'clone_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->belongs_to(group => 'OpenQA::Schema::Result::JobGroups', 'group_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->might_have(origin => 'OpenQA::Schema::Result::Jobs', 'clone_id', {cascade_delete => 0});
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'job_id');
__PACKAGE__->many_to_many(assets => 'jobs_assets', 'asset');
__PACKAGE__->has_many(children => 'OpenQA::Schema::Result::JobDependencies', 'parent_job_id');
__PACKAGE__->has_many(parents  => 'OpenQA::Schema::Result::JobDependencies', 'child_job_id');
__PACKAGE__->has_many(modules  => 'OpenQA::Schema::Result::JobModules',      'job_id', {cascade_delete => 0});
# Locks
__PACKAGE__->has_many(owned_locks  => 'OpenQA::Schema::Result::JobLocks', 'owner');
__PACKAGE__->has_many(locked_locks => 'OpenQA::Schema::Result::JobLocks', 'locked_by');
__PACKAGE__->has_many(comments     => 'OpenQA::Schema::Result::Comments', 'job_id', {order_by => 'id'});

__PACKAGE__->has_many(networks => 'OpenQA::Schema::Result::JobNetworks', 'job_id');

__PACKAGE__->has_many(gru_dependencies => 'OpenQA::Schema::Result::GruDependencies', 'job_id');

__PACKAGE__->add_unique_constraint([qw/slug/]);

__PACKAGE__->filter_column(
    result_dir => {
        filter_to_storage   => 'remove_result_dir_prefix',
        filter_from_storage => 'add_result_dir_prefix',
    });

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_jobs_state',       fields => ['state']);
    $sqlt_table->add_index(name => 'idx_jobs_result',      fields => ['result']);
    $sqlt_table->add_index(name => 'idx_jobs_build_group', fields => [qw/BUILD group_id/]);
    $sqlt_table->add_index(name => 'idx_jobs_scenario',    fields => [qw/VERSION DISTRI FLAVOR TEST MACHINE ARCH/]);
}

# overload to straighten out job modules
sub delete {
    my ($self) = @_;
    # we need to remove the modules one by one to get their delete functions called
    # otherwise dbix leaves this to the database
    $self->modules->delete_all;
    return $self->SUPER::delete;
}

sub name {
    my $self = shift;
    return $self->slug if $self->slug;

    if (!$self->{_name}) {
        my @a;

        my %formats = (BUILD => 'Build%s',);

        for my $c (qw/DISTRI VERSION FLAVOR ARCH BUILD TEST/) {
            next unless $self->get_column($c);
            push @a, sprintf(($formats{$c} || '%s'), $self->get_column($c));
        }
        my $name = join('-', @a);
        $name .= ('@' . $self->get_column('MACHINE')) if $self->get_column('MACHINE');
        $name =~ s/[^a-zA-Z0-9@._+:-]/_/g;
        $self->{_name} = $name;
    }
    return $self->{_name};
}

sub scenario_hash {
    my ($self) = @_;
    my %scenario = map { lc $_ => $self->get_column($_) } SCENARIO_WITH_MACHINE_KEYS;
    return %scenario;
}

# return 0 if we have no worker
sub worker_id {
    my ($self) = @_;
    if ($self->worker) {
        return $self->worker->id;
    }
    return 0;
}

sub settings_hash {
    my ($self) = @_;

    if (!defined($self->{_settings})) {
        $self->{_settings} = {};
        for my $var ($self->settings->all()) {
            if (defined $self->{_settings}->{$var->key}) {
                # handle multi-value WORKER_CLASS
                $self->{_settings}->{$var->key} .= ',' . $var->value;
            }
            else {
                $self->{_settings}->{$var->key} = $var->value;
            }
        }
        for my $c (qw/DISTRI VERSION FLAVOR MACHINE ARCH BUILD TEST/) {
            $self->{_settings}->{$c} = $self->get_column($c);
        }
        $self->{_settings}->{NAME} = sprintf "%08d-%s", $self->id, $self->name;
    }

    return $self->{_settings};
}

sub deps_hash {
    my ($self) = @_;

    if (!defined($self->{_deps_hash})) {
        $self->{_deps_hash} = {
            parents  => {Chained => [], Parallel => []},
            children => {Chained => [], Parallel => []}};
        for my $dep ($self->parents) {
            push @{$self->{_deps_hash}->{parents}->{$dep->to_string}}, $dep->parent_job_id;
        }
        for my $dep ($self->children) {
            push @{$self->{_deps_hash}->{children}->{$dep->to_string}}, $dep->child_job_id;
        }
    }

    return $self->{_deps_hash};
}

sub add_result_dir_prefix {
    my $rd = $_[1];
    $rd = $OpenQA::Utils::resultdir . "/$rd" if $rd;
    return $rd;
}

sub remove_result_dir_prefix {
    my $rd = $_[1];
    $rd = basename($_[1]) if $rd;
    return $rd;
}

sub set_prio {
    my ($self, $prio) = @_;

    $self->update({priority => $prio});
}

sub _hashref {
    my $obj    = shift;
    my @fields = @_;

    my %hashref = ();
    foreach my $field (@fields) {
        my $ref = ref($obj->$field);
        if ($ref =~ /HASH|ARRAY|SCALAR|^$/) {
            $hashref{$field} = $obj->$field;
        }
        elsif ($ref eq 'DateTime') {
            # non standard ref, try to stringify
            $hashref{$field} = $obj->$field->datetime();
        }
        else {
            die "unknown field type: $ref";
        }
    }

    return \%hashref;
}

sub to_hash {
    my ($job, %args) = @_;
    my $j = _hashref($job, qw/id name priority state result clone_id retry_avbl t_started t_finished group_id/);
    if ($j->{group_id}) {
        $j->{group} = $job->group->name;
    }
    $j->{settings} = $job->settings_hash;
    # hashes are left for script compatibility with schema version 38
    $j->{test} = $job->TEST;
    if ($args{assets}) {
        if (defined $job->{_assets}) {
            for my $a (@{$job->{_assets}}) {
                push @{$j->{assets}->{$a->type}}, $a->name;
            }
        }
        else {
            for my $a ($job->jobs_assets->all()) {
                push @{$j->{assets}->{$a->asset->type}}, $a->asset->name;
            }
        }
    }
    if ($args{deps}) {
        $j = {%$j, %{$job->deps_hash}};
    }
    return $j;
}

=head2 can_be_duplicated

=over

=item Arguments: none

=item Return value: 1 if a new clone can be created. undef otherwise.

=back

Checks if a given job can be duplicated - not cloned yet and in correct state.

=cut
sub can_be_duplicated {
    my ($self) = @_;

    my $state = $self->state;
    return unless (grep { /$state/ } (EXECUTION_STATES, FINAL_STATES));
    return if $self->clone;
    return 1;
}

=head2 duplicate

=over

=item Arguments: optional hash reference containing the key 'prio'

=item Return value: the new job or array of duplicated jobs if duplication suceeded,
                    undef otherwise

=back

Clones the job creating a new one with the same settings and linked through
the 'clone' relationship. This method uses optimistic locking and database
transactions to ensure that only one clone is created per job. If the job
already have a job or the creation fails (most likely due to a concurrent
duplication detected by the optimistic locking), the method returns undef.

Rules for dependencies cloning are:
for PARALLEL dependencies:
- clone parents
 + if parent state is SCHEDULED, just create dependency
 + if parent is clone, find the latest clone and clone it
- clone children
 + if clone state is SCHEDULED, route child to us (remove original dependency)
 + if child is DONE, ignore. Dependency is transitivelly preserved by depending on parent's clone's origin
 + if child is clone, find the latest clone and clone it

for CHAINED dependencies:
- do NOT clone parents
 + create new dependency - duplicit cloning is prevented by ignorelist, webui will show multiple chained deps though
- clone children
 + if clone state is SCHEDULED, route child to us (remove original dependency)
 + if child is clone, find the latest clone and clone it

=cut
sub duplicate {
    my $self    = shift;
    my $args    = shift || {};
    my $rsource = $self->result_source;
    my $schema  = $rsource->schema;

    # If the job already has a clone, none is created
    return unless $self->can_be_duplicated;
    # skip this job if encountered again
    my $jobs_map = $args->{jobs_map} // {};
    $jobs_map->{$self->id} = 0;
    log_debug('duplicating ' . $self->id);

    # store mapping of all duplications for return - need old job IDs for state mangling
    my %duplicated_ids;
    my @direct_deps_parents_parallel  = ();
    my @direct_deps_parents_chained   = ();
    my @direct_deps_children_parallel = ();
    my @direct_deps_children_chained  = ();

    # we can start traversing clone graph anywhere, so first we travers upwards then downwards
    # since we do this in each duplication, we need to prevent double cloning of ourselves
    # i.e. to preven cloned parent to clone its children

    ## now go and clone and recreate test dependencies - parents first
    my $parents = $self->parents->search(
        {
            dependency => {-in => [OpenQA::Schema::Result::JobDependencies->PARALLEL, OpenQA::Schema::Result::JobDependencies->CHAINED]},
        },
        {
            join => 'parent',
        });
    while (my $pd = $parents->next) {
        my $p = $pd->parent;
        if (!exists $jobs_map->{$p->id}) {
            # if jobs_map->{$p->id} doesn't exists, the job processing wasnt started yet, do it now
            if ($pd->dependency eq OpenQA::Schema::Result::JobDependencies->PARALLEL) {
                my %dups = $p->duplicate({jobs_map => $jobs_map});
                # if duplication failed, either there was a transaction conflict or more likely job failed
                # can_be_duplicated check.
                # That is either we are hooked to already cloned parent or
                # parent is not in proper state - e.g. scheduled.
                while (!%dups && !$p->can_be_duplicated) {
                    if ($p->state eq SCHEDULED) {
                        # we use SCHEDULED as is, just route dependencies
                        %dups = ($p->id => $p->id);
                        last;
                    }
                    else {
                        # find the current clone and try to duplicate that one
                        while ($p->clone) {
                            $p = $p->clone;
                        }
                        %dups = $p->duplicate({jobs_map => $jobs_map});
                    }
                }
                %duplicated_ids = (%duplicated_ids, %dups);
                # we don't have our cloned id yet so store new immediate parent for
                # dependency recreation
                push @direct_deps_parents_parallel, $dups{$p->id};
            }
            else {
                # reroute to CHAINED parents, those are not being cloned when child is restarted
                push @direct_deps_parents_chained, $p->id;
            }
        }
        elsif ($jobs_map->{$p->id}) {
            # if $jobs_map->{$p->id} is true, job was already clones, lets create the relationship
            if ($pd->dependency eq OpenQA::Schema::Result::JobDependencies->PARALLEL) {
                push @direct_deps_parents_parallel, $jobs_map->{$p->id};
            }
            else {
                push @direct_deps_parents_chained, $p->id;
            }
        }
        # else ignore since the jobs is being processed and we are also indirect descendand
    }

    ## go and clone and recreate test dependencies - running children tests, this cover also asset dependencies (use CHAINED dep)
    my $children = $self->children->search(
        {
            dependency => {-in => [OpenQA::Schema::Result::JobDependencies->PARALLEL, OpenQA::Schema::Result::JobDependencies->CHAINED]},
        },
        {
            join => 'child',
        });
    while (my $cd = $children->next) {
        my $c = $cd->child;
        # ignore already cloned child, prevent loops in test definition
        next if $duplicated_ids{$c->id};
        # do not clone DONE children for PARALLEL deps
        next if ($c->state eq DONE and $cd->dependency eq OpenQA::Schema::Result::JobDependencies->PARALLEL);

        if (!exists $jobs_map->{$c->id}) {
            # if jobs_map->{$p->id} doesn't exists, the job processing wasnt started yet, do it now
            my %dups = $c->duplicate({jobs_map => $jobs_map});
            # the same as in parent cloning, detect SCHEDULED and cloning already cloned child
            while (!%dups && !$c->can_be_duplicated) {
                if ($c->state eq SCHEDULED) {
                    # we use SCHEDULED as is, just route dependencies - create new, remove existing
                    %dups = ($c->id => $c->id);
                    $cd->delete;
                    last;
                }
                else {
                    # find the current clone and try to duplicate that one
                    while ($c->clone) {
                        $c = $c->clone;
                    }
                    %dups = $c->duplicate({jobs_map => $jobs_map});
                }
            }
            # we don't have our cloned id yet so store immediate child for
            # dependency recreation
            if ($cd->dependency eq OpenQA::Schema::Result::JobDependencies->PARALLEL) {
                push @direct_deps_children_parallel, $dups{$c->id};
            }
            else {
                push @direct_deps_children_chained, $dups{$c->id};
            }
            %duplicated_ids = (%duplicated_ids, %dups);
        }
        elsif ($jobs_map->{$c->id}) {
            if ($cd->dependency eq OpenQA::Schema::Result::JobDependencies->PARALLEL) {
                push @direct_deps_children_parallel, $jobs_map->{$c->id};
            }
            else {
                push @direct_deps_children_chained, $jobs_map->{$c->id};
            }
        }
    }

    # Copied retry_avbl as default value if the input undefined
    $args->{retry_avbl} = $self->retry_avbl unless defined $args->{retry_avbl};
    # Code to be executed in a transaction to perform optimistic locking on
    # clone_id
    my $coderef = sub {
        # Duplicate settings (except NAME and TEST and JOBTOKEN)
        my @new_settings;
        my $settings = $self->settings;

        while (my $js = $settings->next) {
            unless ($js->key =~ /^(NAME|TEST|JOBTOKEN)$/) {
                push @new_settings, {key => $js->key, value => $js->value};
            }
        }

        my $new_job = $rsource->resultset->create(
            {
                TEST     => $self->TEST,
                VERSION  => $self->VERSION,
                ARCH     => $self->ARCH,
                FLAVOR   => $self->FLAVOR,
                MACHINE  => $self->MACHINE,
                BUILD    => $self->BUILD,
                DISTRI   => $self->DISTRI,
                group_id => $self->group_id,
                settings => \@new_settings,
                # assets are re-created in job_grab
                priority => $args->{prio} || $self->priority,
                retry_avbl => $args->{retry_avbl},
            });
        # Perform optimistic locking on clone_id. If the job is not longer there
        # or it already has a clone, rollback the transaction (new_job should
        # not be created, somebody else was faster at cloning)
        my $upd = $rsource->resultset->search({clone_id => undef, id => $self->id})->update({clone_id => $new_job->id});

        die('There is already a clone!') unless ($upd == 1);    # One row affected
        return $new_job;
    };

    my $res;

    try {
        $res = $schema->txn_do($coderef);
        $res->discard_changes;                                  # Needed to load default values from DB
    }
    catch {
        my $error = shift;
        log_debug("rollback duplicate: $error");
        die "Rollback failed during failed job cloning!"
          if ($error =~ /Rollback failed/);
        $res = undef;
    };
    unless ($res) {
        # if we didn't die, there is already a clone.
        # TODO: why this wasn't catched by can_be_duplicated? Tests are testing this scenario
        # return here may leave inconsistent job dependencies
        return;
    }

    # recreate dependencies if exists for cloned parents/children
    for my $p (@direct_deps_parents_parallel) {
        $res->parents->create(
            {
                parent_job_id => $p,
                dependency    => OpenQA::Schema::Result::JobDependencies->PARALLEL,
            });
    }
    for my $p (@direct_deps_parents_chained) {
        $res->parents->create(
            {
                parent_job_id => $p,
                dependency    => OpenQA::Schema::Result::JobDependencies->CHAINED,
            });
    }
    for my $c (@direct_deps_children_parallel) {
        $res->children->create(
            {
                child_job_id => $c,
                dependency   => OpenQA::Schema::Result::JobDependencies->PARALLEL,
            });
    }
    for my $c (@direct_deps_children_chained) {
        $res->children->create(
            {
                child_job_id => $c,
                dependency   => OpenQA::Schema::Result::JobDependencies->CHAINED,
            });
    }

    # when dependency network is recreated, associate assets
    $res->register_assets_from_settings;
    # we are done, mark it in jobs_map
    $jobs_map->{$self->id} = $res->id;
    return ($self->id => $res->id, %duplicated_ids);
}

sub set_property {
    my ($self, $key, $value) = @_;
    my $r = $self->settings->find({key => $key});
    if (defined $value) {
        if ($r) {
            $r->update({value => $value});
        }
        else {
            $self->settings->create(
                {
                    job_id => $self->id,
                    key    => $key,
                    value  => $value
                });
        }
    }
    elsif ($r) {
        $r->delete;
    }
}

# calculate overall result looking at the job modules
sub calculate_result($) {
    my ($job) = @_;

    my $overall;
    my $important_overall;    # just counting importants

    for my $m ($job->modules->all) {
        if ($m->result eq PASSED) {
            if ($m->important || $m->fatal) {
                $important_overall ||= PASSED;
            }
            $overall ||= PASSED;
        }
        elsif ($m->result eq SOFTFAILED) {
            if ($m->important || $m->fatal) {
                if (!defined $important_overall || $important_overall eq PASSED) {
                    $important_overall = SOFTFAILED;
                }
            }
            if (!defined $overall || $overall eq PASSED) {
                $overall = SOFTFAILED;
            }
        }
        else {
            if ($m->important || $m->fatal) {
                $important_overall = FAILED;
            }
            $overall = FAILED;
        }
    }
    # don't let go with overall PASSED if there were fails
    if (($overall || FAILED) ne PASSED && ($important_overall || '') eq PASSED) {
        $important_overall = SOFTFAILED;
    }

    return $important_overall || $overall || FAILED;
}

sub save_screenshot($) {
    my ($self, $screen) = @_;
    return unless length($screen->{name});

    my $tmpdir = $self->worker->get_property('WORKER_TMPDIR');
    return unless -d $tmpdir;    # we can't help
    my $current = readlink($tmpdir . "/last.png");
    my $newfile = OpenQA::Utils::save_base64_png($tmpdir, $screen->{name}, $screen->{png});
    unlink($tmpdir . "/last.png");
    symlink("$newfile.png", $tmpdir . "/last.png");
    # remove old file
    unlink($tmpdir . "/$current") if $current;
}

sub append_log($) {
    my ($self, $log) = @_;
    return unless length($log->{data});

    my $file = $self->worker->get_property('WORKER_TMPDIR');
    return unless -d $file;    # we can't help
    $file .= "/autoinst-log-live.txt";
    if (sysopen(my $fd, $file, Fcntl::O_WRONLY | Fcntl::O_CREAT)) {
        sysseek($fd, $log->{offset}, Fcntl::SEEK_SET);
        syswrite($fd, $log->{data});
        close($fd);
    }
    else {
        print STDERR "can't open $file: $!\n";
    }
}

sub update_backend($) {
    my ($self, $backend_info) = @_;
    $self->update(
        {
            backend      => $backend_info->{backend},
            backend_info => JSON::encode_json($backend_info->{backend_info})});
}

sub insert_module($$) {
    my ($self, $tm) = @_;
    my $r = $self->modules->find_or_new({name => $tm->{name}});
    if (!$r->in_storage) {
        $r->category($tm->{category});
        $r->script($tm->{script});
        $r->insert;
    }
    $r->update(
        {
            milestone => $tm->{flags}->{milestone} ? 1 : 0,
            important => $tm->{flags}->{important} ? 1 : 0,
            fatal     => $tm->{flags}->{fatal}     ? 1 : 0,
        });
    return $r;
}

sub insert_test_modules($) {
    my ($self, $testmodules) = @_;
    for my $tm (@{$testmodules}) {
        $self->insert_module($tm);
    }
}

# check the group comments for tags
sub part_of_important_build {
    my ($self) = @_;

    my $build = $self->BUILD;

    # if there is no group, it can't be important
    if (!$self->group) {
        return;
    }

    my $comments = $self->group->comments;
    my $important;
    while (my $comment = $comments->next) {
        my @tag = $comment->tag;
        next unless $tag[0] and ($tag[0] eq $build);
        if ($tag[1] eq 'important') {
            $important = 1;
        }
        elsif ($tag[1] eq '-important') {
            $important = 0;
        }
    }
    return $important;
}

# gru job
sub reduce_result {
    my ($app, $args) = @_;

    if (!ref($args)) {
        $args = {resultdir => $args};
    }

    if ($args->{jobid}) {
        my $job = $app->db->resultset('Jobs')->find({id => $args->{jobid}});
        if ($job->part_of_important_build) {
            $app->log->debug('Job ' . $job->id . ' is part of important build, skip cleanup');
            return;
        }
    }

    my $resultdir = $args->{resultdir};
    $resultdir .= "/";
    unlink($resultdir . "autoinst-log.txt");
    unlink($resultdir . "video.ogv");
    unlink($resultdir . "serial0.txt");
    File::Path::rmtree($resultdir . "ulogs");
}

sub create_result_dir {
    my ($self) = @_;
    my $dir = $self->result_dir();
    if (!$dir) {
        $dir = sprintf "%08d-%s", $self->id, $self->name;
        $self->update({result_dir => $dir});
        $dir = $self->result_dir();
    }
    if (!-d $dir) {
        my $days = 30;
        $days = $self->group->keep_logs_in_days if $self->group;
        my $cleanday = DateTime->now()->add(days => $days);
        my %args = (resultdir => $dir, jobid => $self->id);
        $OpenQA::Utils::app->gru->enqueue(reduce_result => \%args, {run_at => $cleanday});
        mkdir($dir) || die "can't mkdir $dir: $!";
    }
    my $sdir = $dir . "/.thumbs";
    if (!-d $sdir) {
        mkdir($sdir) || die "can't mkdir $sdir: $!";
    }
    $sdir = $dir . "/ulogs";
    if (!-d $sdir) {
        mkdir($sdir) || die "can't mkdir $sdir: $!";
    }
    return $dir;
}

sub update_module {
    my ($self, $name, $result, $cleanup) = @_;

    $cleanup //= 0;
    my $mod = $self->modules->find({name => $name});
    return unless $mod;
    $self->create_result_dir();

    $mod->update_result($result);
    return $mod->save_details($result->{details}, $cleanup);
}

sub running_modinfo() {
    my ($self) = @_;

    my @modules = OpenQA::Schema::Result::JobModules::job_modules($self);

    my $modlist   = [];
    my $donecount = 0;
    my $count     = int(@modules);
    my $modstate  = 'done';
    my $running;
    my $category;
    for my $module (@modules) {
        my $name   = $module->name;
        my $result = $module->result;
        if (!$category || $category ne $module->category) {
            $category = $module->category;
            push @$modlist, {category => $category, modules => []};
        }
        if ($result eq 'running') {
            $modstate = 'current';
            $running  = $name;
        }
        elsif ($modstate eq 'current') {
            $modstate = 'todo';
        }
        elsif ($modstate eq 'done') {
            $donecount++;
        }
        my $moditem = {name => $name, state => $modstate, result => $result};
        push @{$modlist->[scalar(@$modlist) - 1]->{modules}}, $moditem;
    }
    return {
        modlist  => $modlist,
        modcount => $count,
        moddone  => $donecount,
        running  => $running
    };
}

sub store_image {
    my ($self, $asset, $md5, $thumb) = @_;

    my ($storepath, $thumbpath) = OpenQA::Utils::image_md5_filename($md5);
    $storepath = $thumbpath if ($thumb);
    my $prefixdir = dirname($storepath);
    mkdir($prefixdir) unless (-d $prefixdir);
    $asset->move_to($storepath);
    log_debug("store_image: $storepath");
}

sub create_artefact {
    my ($self, $asset, $ulog) = @_;

    $ulog //= 0;

    my $storepath = $self->create_result_dir();
    return unless $storepath && -d $storepath;

    if ($ulog) {
        $storepath .= "/ulogs";
    }

    $asset->move_to(join('/', $storepath, $asset->filename));
    log_debug("moved to $storepath " . $asset->filename);

    # mark the worker as alive
    if ($self->worker) {
        $self->worker->seen;
    }
    else {
        log_warning($self->id . " got an artefact but has no worker. huh?");
    }

    1;
}

sub create_asset {
    my ($self, $asset, $scope) = @_;

    my $fname = $asset->filename;

    # FIXME: pass as parameter to avoid guessing
    my $type;
    $type = 'iso' if $fname =~ /\.iso$/;
    $type = 'hdd' if $fname =~ /\.(?:qcow2|raw)$/;
    $type //= 'other';

    $fname = sprintf("%08d-%s", $self->id, $fname) if $scope ne 'public';

    my $fpath = join('/', $OpenQA::Utils::assetdir, $type);

    if (!-d $fpath) {
        mkdir($fpath) || die "can't mkdir $fpath: $!";
    }

    my $suffix = '.TEMP-' . db_helpers::rndstr(8);
    my $abs = join('/', $fpath, $fname . $suffix);
    $asset->move_to($abs);
    log_debug("moved to $abs");
    $self->jobs_assets->create({job => $self, asset => {name => $fname, type => $type}, created_by => 1});

    # mark the worker as alive
    if ($self->worker) {
        $self->worker->seen;
    }
    else {
        log_warning($self->id . " got an asset but has no worker. huh?");
    }

    return $abs;
}

sub failed_modules_with_needles {

    my ($self) = @_;

    my $fails = $self->modules->search({result => 'failed'});
    my $failedmodules = {};

    while (my $module = $fails->next) {

        my @needles;

        my $counter = 0;
        for my $detail (@{$module->details}) {
            $counter++;
            next unless $detail->{result} eq 'fail';
            for my $needle (@{$detail->{needles}}) {
                push @needles, [$needle->{name}, $counter];
            }
        }
        if (!@needles) {
            push @needles, [undef, $counter];
        }
        $failedmodules->{$module->name} = \@needles;
    }
    return $failedmodules;
}

sub update_status {
    my ($self, $status) = @_;

    my $ret = {result => 1};

    if (!$self->worker) {
        log_warning($self->id . " got a status update but has no worker. huh?");
        return $ret;
    }

    # that is a bit of an abuse as we don't have anything of the
    # other payload
    if ($status->{uploading}) {
        $self->update({state => UPLOADING});
        return $ret;
    }

    $self->append_log($status->{log});
    # delete from the hash so it becomes dumpable for debugging
    my $screen = delete $status->{screen};
    $self->save_screenshot($screen)                   if $screen;
    $self->update_backend($status->{backend})         if $status->{backend};
    $self->insert_test_modules($status->{test_order}) if $status->{test_order};
    my %known;
    if ($status->{result}) {
        while (my ($name, $result) = each %{$status->{result}}) {
            # in interactive mode, updating the symbolic link if needed
            my $existent = $self->update_module($name, $result, $status->{status}->{needinput}) || [];
            for (@$existent) { $known{$_} = 1; }
        }
    }
    $ret->{known_images} = [sort keys %known];

    $self->worker->set_property("INTERACTIVE", $status->{status}->{interactive} // 0);
    # mark the worker as alive
    $self->worker->seen;

    if ($status->{status}->{needinput}) {
        if ($self->state eq RUNNING) {
            $self->state(WAITING);
        }
    }
    else {
        if ($self->state eq WAITING) {
            $self->state(RUNNING);
        }
    }
    $self->update();

    # result=1 for the call, job_result for the current state
    $ret->{job_result} = $self->calculate_result();

    return $ret;
}

sub register_assets_from_settings {
    my ($self) = @_;
    my $settings = $self->settings_hash;

    my %assets = %{parse_assets_from_settings($settings)};

    return unless keys %assets;

    for my $a (values %assets) {
        return if $a->{name} =~ /\//;    # TODO: use whitelist?
    }

    my @parents_rs = $self->parents->search(
        {
            dependency => OpenQA::Schema::Result::JobDependencies->CHAINED,
        },
        {
            columns => ['parent_job_id'],
        });
    my @parents = map { $_->parent_job_id } @parents_rs;

    # updated settings with actual file names
    my %updated;

    # check assets and fix the file names
    for my $k (keys %assets) {
        my $a = $assets{$k};
        my $f_asset = _asset_find($a->{name}, $a->{type}, \@parents);
        unless (defined $f_asset) {
            # don't register asset not yet available
            delete $assets{$k};
            next;
        }
        $a->{name} = $f_asset;
        $updated{$k} = $f_asset;
    }

    for my $a (values %assets) {
        # avoid plain create or we will get unique constraint problems
        # in case ISO_1 and ISO_2 point to the same ISO
        my $aid = $self->result_source->schema->resultset('Assets')->find_or_create($a);
        $self->jobs_assets->find_or_create({asset_id => $aid->id});
    }

    return \%updated;
}

sub _asset_find {
    my ($name, $type, $parents) = @_;

    # add undef to parents so that we chek regular assets too
    for my $parent (@$parents, undef) {
        my $fname = $parent ? sprintf("%08d-%s", $parent, $name) : $name;
        my $path = join('/', $OpenQA::Utils::assetdir, $type, $fname);
        return $fname if -e $path;
    }
    return;
}

sub allocate_network {
    my ($self, $name) = @_;

    my $vlan = $self->_find_network($name);
    return $vlan if $vlan;

    #allocate new
    my @used_rs = $self->result_source->schema->resultset('JobNetworks')->search(
        {},
        {
            columns  => ['vlan'],
            group_by => ['vlan'],
        });
    my %used = map { $_->vlan => 1 } @used_rs;

    for ($vlan = 1;; $vlan++) {
        if (!$used{$vlan}) {
            $self->networks->find_or_create({name => $name, vlan => $vlan});
            return $vlan;
        }
    }
}

sub _find_network {
    my ($self, $name, $seen) = @_;

    $seen //= {};

    return if $seen->{$self->id};
    $seen->{$self->id} = 1;

    my $net = $self->networks->find({name => $name});
    return $net->vlan if $net;

    my $parents = $self->parents->search(
        {
            dependency => OpenQA::Schema::Result::JobDependencies->PARALLEL,
        });
    while (my $pd = $parents->next) {
        my $vlan = $pd->parent->_find_network($name, $seen);
        return $vlan if $vlan;
    }

    my $children = $self->children->search(
        {
            dependency => OpenQA::Schema::Result::JobDependencies->PARALLEL,
        });
    while (my $cd = $children->next) {
        my $vlan = $cd->child->_find_network($name, $seen);
        return $vlan if $vlan;
    }
}

sub release_networks {
    my ($self) = @_;

    $self->networks->delete;
}

sub needle_dir() {
    my ($self) = @_;
    unless ($self->{_needle_dir}) {
        my $distri  = $self->DISTRI;
        my $version = $self->VERSION;
        $self->{_needle_dir} = OpenQA::Utils::needledir($distri, $version);
    }
    return $self->{_needle_dir};
}

# return the last X complete jobs of the same scenario
sub _previous_scenario_jobs {
    my ($self, $rows) = @_;

    my $schema = $self->result_source->schema;
    my $conds = [{'me.state' => 'done'}, {'me.result' => [COMPLETE_RESULTS]}, {'me.id' => {'<', $self->id}}];
    for my $key (SCENARIO_WITH_MACHINE_KEYS) {
        push(@$conds, {"me.$key" => $self->get_column($key)});
    }
    my %attrs = (
        order_by => ['me.id DESC'],
        rows     => $rows
    );
    return $schema->resultset("Jobs")->search({-and => $conds}, \%attrs)->all;
}

# internal function to compare two failure reasons
sub _failure_reason {
    my ($self) = @_;

    if (!grep { $_ eq $self->result } (FAILED, SOFTFAILED, INCOMPLETE)) {
        return 'GOOD';
    }

    my @failed_modules;
    my $modules = $self->modules;
    while (my $m = $modules->next) {
        if ($m->result eq FAILED || $m->result eq SOFTFAILED) {
            # in case we don't see an important module, we return all modules
            push(@failed_modules, $m->name);
        }
        if ($m->result eq FAILED && ($m->important || $m->fatal)) {
            return $m->name;
        }
    }
    return join('', @failed_modules) || $self->result;
}

sub _carry_over_candidate {
    my ($self) = @_;

    my $current_failure_reason = $self->_failure_reason;
    my $prev_failure_reason    = '';
    my $state_changes          = 0;

    # search for previous jobs
    for my $job ($self->_previous_scenario_jobs(20)) {
        my $job_fr = $job->_failure_reason;

        log_debug(sprintf("checking take over from %d: %s vs %s", $job->id, $job_fr, $current_failure_reason));
        # we found a good candidate
        return $job if $job_fr eq $current_failure_reason;

        # ignore jobs with repeated problems
        next if ($job_fr eq $prev_failure_reason);

        $prev_failure_reason = $job_fr;
        $state_changes++;

        # if the job changed failures more often, we assume
        # that the carry over is pointless
        return if $state_changes > 4;
    }
    return;
}

=head2 carry_over_labels

carry over labels (i.e. special comments) from previous jobs to current result
in the same scenario.

=cut
sub carry_over_labels {
    my ($self) = @_;

    # the carry over makes only sense for some jobs
    return if !grep { $_ eq $self->result } (FAILED, SOFTFAILED, INCOMPLETE);

    my $prev = $self->_carry_over_candidate;
    return if !$prev;

    my $comments = $prev->comments->search({}, {order_by => {-desc => 'me.id'}});

    while (my $comment = $comments->next) {
        next if !($comment->bugref or $comment->label);

        my $text = $comment->text;
        if ($text !~ "Automatic takeover") {
            $text .= "\n\n(Automatic takeover from t#" . $prev->id . ")\n";
        }
        my %newone = (text => $text);
        # TODO can we also use another user id to tell that
        # this comment was created automatically and not by a
        # human user?
        $newone{user_id} = $comment->user_id;
        $self->comments->create(\%newone);
        last;
    }
    return;
}

sub running_or_waiting {
    my ($self) = @_;
    return ($self->state eq 'running' || $self->state eq 'waiting');
}

# extend to finish
sub store_column {
    my ($self, %args) = @_;
    if ($args{state} && grep { $args{state} eq $_ } FINAL_STATES) {
        if (!$self->t_finished) {
            # make sure we do not overwrite a t_finished from fixtures
            # in normal operation it should be impossible to finish
            # twice
            $self->t_finished(now());
        }
        # make sure no modules are left running
        $self->modules->search({result => RUNNING})->update({result => NONE});
    }
    return $self->SUPER::store_column(%args);
}

# parent job failed, handle scheduled children - set them to done incomplete immediately
sub _job_skip_children {
    my ($self) = @_;
    my $jobs = $self->children->search(
        {
            'child.state' => SCHEDULED,
        },
        {join => 'child'});

    my $count = 0;
    while (my $j = $jobs->next) {
        $j->child->update(
            {
                state  => CANCELLED,
                result => SKIPPED,
            });
        $count += $j->child->_job_skip_children;
    }
    return $count;
}

# parent job failed, handle running children - send stop command
sub _job_stop_children {
    my ($self) = @_;

    my $children = $self->children->search(
        {
            dependency    => OpenQA::Schema::Result::JobDependencies->PARALLEL,
            'child.state' => [EXECUTION_STATES],
        },
        {join => 'child'});

    my $count = 0;
    my $jobs  = $children->search(
        {
            result => NONE,
        });
    while (my $j = $jobs->next) {
        $j->child->update(
            {
                result => PARALLEL_FAILED,
            });
        $count += 1;
    }

    while (my $j = $children->next) {
        $j->child->worker->send_command(command => 'cancel', job_id => $j->child->id);
        $count += $j->child->_job_stop_children;
    }
    return $count;
}

=head2 done

Finalize job by setting it as DONE.

Accepted optional arguments:
  newbuild => 0/1
  result   => see RESULTS

newbuild set marks build as OBSOLETED
if result is not set (expected default situation) result is computed from the results of individual
test modules

=cut
sub done {
    my ($self, %args) = @_;
    my $newbuild = 0;
    $newbuild = int($args{newbuild}) if defined $args{newbuild};
    $args{result} = OBSOLETED if $newbuild;

    # cleanup
    $self->set_property('JOBTOKEN');
    $self->release_networks();
    $self->owned_locks->delete;
    $self->locked_locks->update({locked_by => undef});
    if ($self->worker) {
        # free the worker
        $self->worker->update({job_id => undef});
    }

    # update result if not provided
    my $result = $args{result} || $self->calculate_result();
    my %new_val = (state => DONE);
    # for cancelled jobs the result is already known
    $new_val{result} = $result if $self->result eq NONE;

    $self->update(\%new_val);

    if (!grep { $result eq $_ } (PASSED, SOFTFAILED)) {
        $self->_job_skip_children;
        $self->_job_stop_children;
    }
    # labels are there to mark reasons of failure - the function checks itself though
    $self->carry_over_labels;

    return $result;
}

sub cancel {
    my ($self, $obsoleted) = @_;
    $obsoleted //= 0;
    my $result = $obsoleted ? OBSOLETED : USER_CANCELLED;
    return if ($self->result ne NONE);
    my $state = $self->state;
    $self->update(
        {
            state  => CANCELLED,
            result => $result
        });

    my $count = 1;
    if (grep { $state eq $_ } EXECUTION_STATES) {
        $self->worker->send_command(command => 'cancel', job_id => $self->id);
        $count += $self->_job_skip_children;
        $count += $self->_job_stop_children;
    }
    return $count;
}
1;
# vim: set sw=4 et:
