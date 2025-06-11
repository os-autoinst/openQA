# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# a lot of this is inspired (and even in parts copied) from Minion (Artistic-2.0)
package OpenQA::Shared::Plugin::Gru;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Minion;
use DBIx::Class::Timestamps 'now';
use OpenQA::App;
use OpenQA::Schema;
use OpenQA::Shared::GruJob;
use OpenQA::Log qw(log_debug log_info);
use OpenQA::Utils qw(sharedir);
use Mojo::Pg;
use Mojo::Promise;
use Mojo::File qw(path);
use Mojo::JSON qw(decode_json);
use Feature::Compat::Try;

has app => undef, weak => 1;
has 'dsn';

sub new ($class, $app = undef) {
    my $self = $class->SUPER::new;
    return $self->app($app);
}

sub register_tasks ($self) {
    my $app = $self->app;
    $app->plugin($_) for qw(
      OpenQA::Task::AuditEvents::Limit
      OpenQA::Task::Asset::Download
      OpenQA::Task::Asset::Limit
      OpenQA::Task::Git::Clone
      OpenQA::Task::Needle::Scan
      OpenQA::Task::Needle::Save
      OpenQA::Task::Needle::Delete
      OpenQA::Task::Needle::LimitTempRefs
      OpenQA::Task::Job::Limit
      OpenQA::Task::Job::ArchiveResults
      OpenQA::Task::Job::FinalizeResults
      OpenQA::Task::Job::HookScript
      OpenQA::Task::Job::Restart
      OpenQA::Task::Iso::Schedule
      OpenQA::Task::Bug::Limit
    );
}

# allow the continuously polled stats to be available on an
# unauthenticated route to prevent recurring broken requests to the login
# provider if not logged in
#
# hard/impossible to mock due to name collision of "remove" method on
# Test::MockObject, hence marking as
# uncoverable statement
sub _allow_unauthenticated_minion_stats ($app) {
    my $route = $app->routes->find('minion_stats')->remove;    # uncoverable statement
    $app->routes->any('/minion')->add_child($route);    # uncoverable statement
}

sub register ($self, $app, $config) {
    $self->app($app) unless $self->app;
    my $schema = $app->schema;

    my $conn = Mojo::Pg->new;
    my $connect_info = $schema->storage->connect_info->[0];
    if (ref $connect_info eq 'HASH') {
        $self->dsn($connect_info->{dsn});
        $conn->username($connect_info->{user});
        $conn->password($connect_info->{password});
    }
    else {
        $self->dsn($connect_info);
    }
    $conn->dsn($self->dsn());

    # set the search path in accordance with the test setup done in OpenQA::Test::Database
    if (my $search_path = $schema->search_path_for_tests) {
        log_info("setting database search path to $search_path when registering Minion plugin");
        $conn->search_path([$search_path]);
    }

    $app->plugin(Minion => {Pg => $conn});

    my $minion_job_max_age = OpenQA::App->singleton->config->{misc_limits}->{minion_job_max_age};
    $self->app->minion->remove_after($minion_job_max_age) if $minion_job_max_age;

    # We use a custom job class (for legacy reasons)
    $app->minion->on(
        worker => sub ($minion, $worker) {
            $worker->on(
                dequeue => sub ($worker, $job) {
                    # Reblessing the job is fine for now, but in the future it would be nice
                    # to use a role instead
                    bless $job, 'OpenQA::Shared::GruJob';
                });
        });

    $self->register_tasks;

    # Enable the Minion Admin interface under /minion
    my $auth = $app->routes->under('/minion')->to('session#ensure_admin');
    $app->plugin('Minion::Admin' => {route => $auth});
    _allow_unauthenticated_minion_stats($app);
    my $gru = OpenQA::Shared::Plugin::Gru->new($app);
    $app->helper(gru => sub ($c) { $gru });
}

# counts the number of jobs for a certain task in the specified states
sub count_jobs ($self, $task, $states) {
    my $res = $self->app->minion->backend->list_jobs(0, undef, {tasks => [$task], states => $states});
    return ($res && exists $res->{total}) ? $res->{total} : 0;
}

# checks whether at least on job for the specified task is active
sub is_task_active ($self, $task) {
    return $self->count_jobs($task, ['active']) > 0;
}

# checks if there are worker registered
sub has_workers ($self) { !!$self->app->minion->backend->list_workers(0, 1)->{total} }

# For some tasks with the same args we don't need to repeat them if they were
# enqueued less than a minute ago, like 'git fetch'
sub _find_existing_minion_job ($self, $task, $args, $job_ids) {
    my $schema = OpenQA::Schema->singleton;
    $args = [$args] if ref $args eq 'HASH';
    my $dtf = $schema->storage->datetime_parser;
    my $dbh = $schema->storage->dbh;
    my $sql = q{SELECT id, args, created, state, retries, notes, result FROM minion_jobs
                WHERE state IN ('inactive', 'active', 'finished')
                AND created >= ? AND task = ? AND args = ?
                ORDER BY array_position(array['finished'::varchar, 'inactive'::varchar, 'active'::varchar], state::varchar)
                LIMIT 1};
    my $sth = $dbh->prepare($sql);
    my @args = (
        $dtf->format_datetime(DateTime->now()->subtract(minutes => 1)),
        'git_clone', OpenQA::Schema::Result::GruTasks->encode_json_to_db($args));
    $sth->execute(@args);
    return 0 unless my $job = $sth->fetchrow_hashref;
    # same task was run less than 1 minute ago and finished, nothing to do
    return 1 if $job->{state} eq 'finished';

    my $notes = decode_json $job->{notes};
    $self->_add_jobs_to_gru_task($notes->{gru_id}, $job_ids);
    return 1;
}

sub _add_jobs_to_gru_task ($self, $gru_id, $job_ids) {
    my $schema = OpenQA::Schema->singleton;
    # Wrap in txn_do so we can use savepoints in the method. Necessary for cases
    # where we are not in a transaction. Otherwise it's a noop
    $schema->txn_do(
        sub {
            $schema->svp_begin('try_gru_dependencies');
            for my $id (@$job_ids) {
                # Add job to existing gru task with the same args
                try {
                    my $gru_dep = $schema->resultset('GruDependencies')->create({job_id => $id, gru_task_id => $gru_id})
                }
                catch ($e) {
                    $schema->svp_rollback('try_gru_dependencies');
                    die $e
                      unless $e
                      =~ m/insert or update on table "gru_dependencies" violates foreign key constraint "gru_dependencies_fk_gru_task_id"/i;
                    # if the GruTask was already deleted meanwhile, we can skip
                    # the rest of the jobs, since the wanted task was done
                    log_debug("GruTask $gru_id already gone, skip assigning jobs (message: $e)");
                    last;
                }
            }
            $schema->svp_release('try_gru_dependencies');
        });
}

sub obsolete_minion_jobs ($self, $job_ids) {
    my $minion = $self->app->minion;
    for my $job_id (@$job_ids) {
        if (my $job = $minion->job($job_id)) { $job->note(obsolete => 1) }
    }
}

sub enqueue ($self, $task, $args = [], $options = {}, $jobs = []) {
    my $ttl = $options->{ttl};
    my $limit = $options->{limit} ? $options->{limit} : undef;
    my $notes = $options->{notes} ? $options->{notes} : undef;
    return undef if defined $limit && $self->count_jobs($task, ['inactive']) >= $limit;

    $args = [$args] if ref $args eq 'HASH';

    my $delay = $options->{run_at} && $options->{run_at} > now() ? $options->{run_at} - now() : 0;

    my $schema = OpenQA::Schema->singleton;
    my $priority = $options->{priority} // 0;
    my @jobsarrayhref = map { {job_id => $_} } @$jobs;
    my $gru = $schema->resultset('GruTasks')->create(
        {
            taskname => $task,
            priority => $priority,
            args => $args,
            run_at => $options->{run_at} // now(),
            jobs => \@jobsarrayhref,
        });
    my $gru_id = $gru->id;
    my @ttl = defined $ttl ? (expire => $ttl) : ();
    my @notes = defined $notes ? (%$notes) : ();
    my $parents = $options->{parents};
    my $lax = $options->{lax};
    my %minion_options = (
        @ttl,
        priority => $priority,
        delay => $delay,
        notes => {gru_id => $gru_id, @notes},
        defined $lax ? (lax => $lax) : (),
        defined $parents ? (parents => $parents) : (),
    );
    my $minion_id = $self->app->minion->enqueue($task => $args => \%minion_options);

    return {minion_id => $minion_id, gru_id => $gru_id};
}

# enqueues the limit_assets task with the default parameters
sub enqueue_limit_assets ($self) { $self->enqueue('limit_assets', [], {priority => 0, ttl => 172800, limit => 1}) }

sub enqueue_download_jobs ($self, $downloads, $minion_ids = undef) {
    return unless %$downloads;
    # array of hashrefs job_id => id; this is what create needs
    # to create entries in a related table (gru_dependencies)
    for my $url (keys %$downloads) {
        my ($path, $do_extract, $block_job_ids) = @{$downloads->{$url}};
        my $job = $self->enqueue('download_asset', [$url, $path, $do_extract], {priority => 10}, $block_job_ids);
        push @$minion_ids, $job->{minion_id} if $minion_ids;
    }
}

sub enqueue_git_update_all ($self) {
    my $conf = OpenQA::App->singleton->config->{'scm git'};
    return if $conf->{git_auto_update} ne 'yes';
    my %clones;
    my $testdir = path(sharedir() . '/tests');
    for my $distri ($testdir->list({dir => 1})->each) {
        next if -l $distri;    # no symlinks
        next unless -e $distri->child('.git');
        $clones{$distri} = undef;
        if (-e $distri->child('products')) {
            for my $product ($distri->child('products')->list({dir => 1})->each) {
                next if -l $product;    # no symlinks
                my $needle = $product->child('needles');
                next if -l $needle;    # no symlinks
                next unless -e $needle->child('.git');
                $clones{$needle} = undef;
            }
        }
        else {
            my $needle = $distri->child('needles');
            next unless -e $needle->child('.git');
            $clones{$needle} = undef;
        }
    }
    $self->enqueue('git_clone', \%clones, {priority => 10});
}

sub enqueue_git_clones ($self, $clones, $job_ids, $minion_ids = undef) {
    return unless keys %$clones;
    # $clones is a hashref with paths as keys and git urls as values
    # $job_id is used to create entries in a related table (gru_dependencies)

    # resolve all symlinks in keys of $clones to allow _find_existing_minion_job find and skip identical jobs
    my $clones_sr = {};
    for my $path (keys %$clones) {
        my $path_sr = eval { path($path)->realpath } // $path;
        $clones_sr->{$path_sr} = $clones->{$path};
    }

    my $found = $self->_find_existing_minion_job('git_clone', $clones_sr, $job_ids);
    return $found if $found;
    my $job = $self->enqueue('git_clone', $clones_sr, {priority => 10}, $job_ids);
    push @$minion_ids, $job->{minion_id} if $minion_ids;
    return $job;
}

sub enqueue_and_keep_track {
    my ($self, %args) = @_;

    my $task_name = $args{task_name};
    my $task_description = $args{task_description};
    my $task_args = $args{task_args};
    my $task_options = $args{task_options};

    # set default gru task options
    $task_options = {
        priority => 20,    # high prio as this function is used for user-facing tasks like saving a needle
        ttl => 60,
    } unless ($task_options);

    # check whether Minion worker are available to get a nice error message instead of an inactive job
    if (!$self->has_workers) {
        return Mojo::Promise->reject(
            {error => 'No Minion worker available. The <code>openqa-gru</code> service is likely not running.'});
    }

    # enqueue Minion job
    my $ids = $self->enqueue($task_name => $task_args, $task_options);
    my $minion_id;
    if (ref $ids eq 'HASH') {
        $minion_id = $ids->{minion_id};
    }

    # keep track of the Minion job and continue rendering if it has completed
    return $self->app->minion->result_p($minion_id, {interval => 0.5})->then(
        sub {
            my ($info) = @_;

            unless (ref $info) {
                return Mojo::Promise->reject({error => "Minion job for $task_description has been removed."});
            }
            return $info->{result};
        }
    )->catch(
        sub {
            my ($info) = @_;

            # pass result hash with error message (used by save/delete needle tasks)
            my $result = $info->{result};
            if (ref $result eq 'HASH' && $result->{error}) {
                return Mojo::Promise->reject($result, 500);
            }

            # format error message (fallback for general case)
            my $error_message;
            if (ref $result eq '' && $result) {
                $error_message = "Task for $task_description failed: $result";
            }
            else {
                $error_message = "Task for $task_description failed: Checkout Minion dashboard for further details.";
            }
            return Mojo::Promise->reject({error => $error_message, result => $result}, 500);
        });
}

1;

=encoding utf8

=head1 NAME

OpenQA::Shared::Plugin::Gru - The Gru job queue

=head1 SYNOPSIS

    $app->plugin('OpenQA::Shared::Plugin::Gru');

=head1 DESCRIPTION

L<OpenQA::Shared::Plugin::Gru> is the openQA job queue (and a tiny wrapper
around L<Minion>).

=cut
