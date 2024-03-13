# Copyright 2015-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Resource::Locks;
use Mojo::Base -strict, -signatures;

use OpenQA::Jobs::Constants;
use OpenQA::Schema;

my %final_states = map { $_ => 1 } OpenQA::Jobs::Constants::NOT_OK_RESULTS();

# In normal situation the lock is created by the parent (server)
# and released when a service becomes available and the child (client)
# can lock and use it. That's why the lock are checked for self and parent
# by default.
#
# Sometimes it is useful to let the parent wait for child. The child job
# can be however killed at any time, while the parent will be still running.
# So we have to specify, which child job is supposed to create the lock
# and watch its state.
#
sub _get_lock {
    my ($name, $jobid, $where) = @_;
    return 0 unless defined $name && defined $jobid;
    my $schema = OpenQA::Schema->singleton;
    my $job = $schema->resultset('Jobs')->single({id => $jobid});
    return 0 unless $job;

    # We need to get owner of the lock
    # owner can be one of the parents or ourselves if we have no parent
    my $lock;
    my @maybeowners;
    if ($where eq 'all') {
        push @maybeowners, map { $_->id } ($job, $job->parents->all, $job->children->all);
    }
    elsif ($where =~ /^\d+$/) {
        push @maybeowners, $where;
    }
    else {
        push @maybeowners, map { $_->id } ($job, $job->parents->all);
    }
    return $schema->resultset('JobLocks')->search({name => $name, owner => {-in => \@maybeowners}});
}

# returns -1 on unrecoverable error, 1 on have lock, 0 on try later (lock unavailable)
sub lock {
    my ($name, $jobid, $where) = @_;

    my $lock = _get_lock($name, $jobid, $where)->single;

    if (!$lock and $where =~ /^\d+$/) {
        my $schema = OpenQA::Schema->singleton;
        # prevent deadlock - job that is supposed to create the lock already finished
        return -1
          if $schema->resultset('Jobs')->count({id => $where, state => [OpenQA::Jobs::Constants::FINAL_STATES]});
    }

    # if no lock so far, there is no lock, return as locked
    return 0 unless $lock;

    # lock is locked and not by us
    if ($lock->locked_by) {
        return 0 if ($lock->locked_by != $jobid);
        return 1;
    }
    # we're using optimistic locking, if this succeeded, we were first
    return 1 if ($lock->update({locked_by => $jobid}));
    return 0;
}

sub unlock {
    my ($name, $jobid, $where) = @_;
    my $lock = _get_lock($name, $jobid, $where // 'all')->single;
    return 0 unless $lock;
    # return if not locked
    return 1 unless $lock->locked_by;
    # return if not locked by us
    return 0 unless ($lock->locked_by == $jobid);
    return 1 if ($lock->update({locked_by => undef}));
    return 0;
}

sub create {
    my ($name, $jobid) = @_;
    my $lock = _get_lock($name, $jobid, 'all')->single;
    # nothing if lock already exist
    return 0 if $lock;
    return 0 unless defined $name && defined $jobid;

    # if no lock so far, there is no lock, create one as unlocked
    my $schema = OpenQA::Schema->singleton;
    $lock = $schema->resultset('JobLocks')->create({name => $name, owner => $jobid});
    return 0 unless $lock;
    return 1;
}

## Barriers
# barriers are created with number of expected jobs. Then wait call waits until the expected number of jobs is waiting

sub barrier_create ($name, $jobid, $expected_jobs) {
    return 0 unless $name && $jobid && $expected_jobs;
    my $barriers = _get_lock($name, $jobid, 'all');
    return 0 if $barriers && $barriers->single;
    my $dbh = OpenQA::Schema->singleton->storage->dbh;
    my $sth = $dbh->prepare('INSERT INTO job_locks (name, owner, count) VALUES (?, ?, ?) ON CONFLICT DO NOTHING');
    eval { $sth->execute($name, $jobid, $expected_jobs) };
    die "Unable to create barrier for job $jobid with name '$name': $@" if $@;
    return $sth->rows > 0;
}

sub barrier_wait ($name, $jobid, $where, $check_dead_job) {
    return -1 unless $name && $jobid;
    return -1 unless my $barriers = _get_lock($name, $jobid, $where);
    return -1 unless my $barrier = $barriers->single;

    my $jobschema = OpenQA::Schema->singleton->resultset('Jobs');
    my @jobs = split ',', $barrier->locked_by // '';

    if ($check_dead_job) {
        my @related_ids = map { scalar $_->id } $barrier->owner->parents->all, $barrier->owner->children->all;
        my @results = map { $jobschema->find($_)->result } $jobid, @jobs, @related_ids;
        for my $result (@results) {
            next unless $final_states{$result};
            $barriers->delete;
            return -1;
        }
    }

    if (grep { $_ eq $jobid } @jobs) {
        return 1 if @jobs == $barrier->count;
        return 0;
    }

    push @jobs, $jobid;
    return -1 unless $barriers->update({locked_by => join(',', @jobs)}) > 0;
    return 1 if @jobs == $barrier->count;
    return 0;
}

sub barrier_destroy ($name, $jobid, $where) {
    return 0 unless $name && $jobid;
    return 0 unless my $barriers = _get_lock($name, $jobid, $where);
    return $barriers->delete > 0;
}

1;
