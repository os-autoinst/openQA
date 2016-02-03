# Copyright (C) 2015 SUSE Linux GmbH
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
use base qw/DBIx::Class::Core/;
use Try::Tiny;
use JSON;
use Fcntl;
use DateTime;
use db_helpers;
use OpenQA::Utils qw/log_debug parse_assets_from_settings/;
use File::Basename qw/basename dirname/;
use File::Path ();
use File::Which qw(which);
use strict;
use warnings;

# States
use constant {
    SCHEDULED => 'scheduled',
    RUNNING   => 'running',
    CANCELLED => 'cancelled',
    WAITING   => 'waiting',
    DONE      => 'done',
    #    OBSOLETED => 'obsoleted',
};
use constant STATES => (SCHEDULED, RUNNING, CANCELLED, WAITING, DONE);
use constant PENDING_STATES => (SCHEDULED, RUNNING, WAITING);
use constant EXECUTION_STATES => (RUNNING, WAITING);
use constant FINAL_STATES     => (DONE,    CANCELLED);

# Results
use constant {
    NONE               => 'none',
    PASSED             => 'passed',
    FAILED             => 'failed',
    INCOMPLETE         => 'incomplete',            # worker died or reported some problem
    SKIPPED            => 'skipped',               # dependencies failed before starting this job
    OBSOLETED          => 'obsoleted',             # new iso was posted
    PARALLEL_FAILED    => 'parallel_failed',       # parallel job failed, this job can't continue
    PARALLEL_RESTARTED => 'parallel_restarted',    # parallel job was restarted, this job has to be restarted too
    USER_CANCELLED     => 'user_cancelled',        # cancelled by user via job_cancel
    USER_RESTARTED     => 'user_restarted',        # restarted by user via job_restart
};
use constant RESULTS => (NONE, PASSED, FAILED, INCOMPLETE, SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED);
use constant COMPLETE_RESULTS => (PASSED, FAILED);
use constant INCOMPLETE_RESULTS => (INCOMPLETE, SKIPPED, OBSOLETED, PARALLEL_FAILED, PARALLEL_RESTARTED, USER_CANCELLED, USER_RESTARTED);

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
    worker_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        # FIXME: get rid of worker 0
        default_value => 0,
        #        is_nullable => 1,
    },
    test => {
        data_type => 'text',
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
__PACKAGE__->belongs_to(worker => 'OpenQA::Schema::Result::Workers',   'worker_id');
__PACKAGE__->belongs_to(clone  => 'OpenQA::Schema::Result::Jobs',      'clone_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->belongs_to(group  => 'OpenQA::Schema::Result::JobGroups', 'group_id', {join_type => 'left', on_delete => 'SET NULL'});
__PACKAGE__->might_have(origin => 'OpenQA::Schema::Result::Jobs', 'clone_id', {cascade_delete => 0});
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'job_id');
__PACKAGE__->many_to_many(assets => 'jobs_assets', 'asset');
__PACKAGE__->has_many(children => 'OpenQA::Schema::Result::JobDependencies', 'parent_job_id');
__PACKAGE__->has_many(parents  => 'OpenQA::Schema::Result::JobDependencies', 'child_job_id');
__PACKAGE__->has_many(modules  => 'OpenQA::Schema::Result::JobModules',      'job_id');
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

    $sqlt_table->add_index(name => 'idx_jobs_state',  fields => ['state']);
    $sqlt_table->add_index(name => 'idx_jobs_result', fields => ['result']);
}

sub name {
    my $self = shift;
    return $self->slug if $self->slug;

    if (!$self->{_name}) {
        my $job_settings = $self->settings_hash;
        my @a;

        my %formats = (BUILD => 'Build%s',);

        for my $c (qw/DISTRI VERSION FLAVOR MEDIA ARCH BUILD TEST/) {
            next unless $job_settings->{$c};
            push @a, sprintf(($formats{$c} || '%s'), $job_settings->{$c});
        }
        my $name = join('-', @a);
        $name =~ s/[^a-zA-Z0-9._+:-]/_/g;
        $self->{_name} = $name;
    }
    return $self->{_name};
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

sub machine {
    my ($self) = @_;

    return $self->settings_hash->{MACHINE};
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
    my $j = _hashref($job, qw/id name priority state result worker_id clone_id retry_avbl t_started t_finished test group_id/);
    if ($j->{group_id}) {
        $j->{group} = $job->group->name;
    }
    $j->{settings} = $job->settings_hash;
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
    my $ignores = $args->{ignore_jobs} // [];
    push @$ignores, $self->id;
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
        next if (grep { $_ == $p->id } @$ignores);
        if ($pd->dependency eq OpenQA::Schema::Result::JobDependencies->PARALLEL) {
            my %dups = $p->duplicate({ignore_jobs => $ignores});
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
                    %dups = $p->duplicate({ignore_jobs => $ignores});
                }
            }
            push @$ignores, keys %dups;
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
        next if (grep { $_ == $c->id } @$ignores);
        # ignore already cloned child, prevent loops in test definition
        next if $duplicated_ids{$c->id};
        # do not clone DONE children for PARALLEL deps
        next if ($c->state eq DONE and $cd->dependency eq OpenQA::Schema::Result::JobDependencies->PARALLEL);

        my %dups = $c->duplicate({ignore_jobs => $ignores});
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
                %dups = $c->duplicate({ignore_jobs => $ignores});
            }
        }
        push @$ignores, keys %dups;
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
        push @new_settings, {key => 'TEST', value => $self->test};

        my $new_job = $rsource->resultset->create(
            {
                test     => $self->test,
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
        OpenQA::Utils::log_debug("rollback duplicate: $error");
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
            else {
                $overall ||= PASSED;
            }
        }
        else {
            if ($m->important || $m->fatal) {
                $important_overall = FAILED;
            }
            else {
                $overall = FAILED;
            }
        }
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

# gru job
sub reduce_result {
    my ($app, $resultdir) = @_;

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
        $OpenQA::Utils::app->gru->enqueue(reduce_result => $dir, {run_at => $cleanday});
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
    $mod->save_details($result->{details}, $cleanup);
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

sub optipng {
    my ($app, $path) = @_;
    if (which('optipng')) {
        OpenQA::Utils::log_debug("optipng $path");
        system('optipng', '-quiet', '-preserve', '-o2', $path);
    }
}

sub store_image {
    my ($self, $asset, $md5, $thumb) = @_;

    my ($storepath, $thumbpath) = OpenQA::Utils::image_md5_filename($md5);
    $storepath = $thumbpath if ($thumb);
    my $prefixdir = dirname($storepath);
    mkdir($prefixdir) unless (-d $prefixdir);
    $asset->move_to($storepath);

    $OpenQA::Utils::app->gru->enqueue(optipng => $storepath);

    OpenQA::Utils::log_debug("store_image: $storepath");
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
    OpenQA::Utils::log_debug("moved to $storepath " . $asset->filename);
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

    $asset->move_to(join('/', $fpath, $fname));
    OpenQA::Utils::log_debug("moved to $fpath " . $fname);
    $self->jobs_assets->create({job => $self, asset => {name => $fname, type => $type}, created_by => 1});

    1;
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
            if (!@{$detail->{needles}}) {
                push @needles, [undef, $counter];
            }
        }
        $failedmodules->{$module->name} = \@needles;
    }
    return $failedmodules;
}

sub update_status {
    my ($self, $status) = @_;

    my $ret = {result => 1};

    $self->append_log($status->{log});
    # delete from the hash so it becomes dumpable for debugging
    my $screen = delete $status->{screen};
    $self->save_screenshot($screen)                   if $screen;
    $self->update_backend($status->{backend})         if $status->{backend};
    $self->insert_test_modules($status->{test_order}) if $status->{test_order};
    my %known;
    if ($status->{result}) {
        while (my ($name, $result) = each %{$status->{result}}) {
            my $existant;
            if ($status->{status}->{needinput}) {
                # in interactive mode, updating the symbolic link if needed
                $existant = $self->update_module($name, $result, 1) || [];
            }
            else {
                $existant = $self->update_module($name, $result) || [];
            }
            for (@$existant) { $known{$_} = 1; }
        }
    }
    $ret->{known_images} = [sort keys %known];

    if ($self->worker_id) {
        $self->worker->set_property("INTERACTIVE", $status->{status}->{interactive} // 0);
    }
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
        my $distri  = $self->settings_hash->{DISTRI};
        my $version = $self->settings_hash->{VERSION};
        $self->{_needle_dir} = OpenQA::Utils::needledir($distri, $version);
    }
    return $self->{_needle_dir};
}

1;
# vim: set sw=4 et:
