# Copyright 2015-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Resource::Locks;

use strict;
use warnings;

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
# and watch it's state.
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
    return $schema->resultset('JobLocks')->search({name => $name, owner => {-in => \@maybeowners}})->single;
}

# returns -1 on unrecoverable error, 1 on have lock, 0 on try later (lock unavailable)
sub lock {
    my ($name, $jobid, $where) = @_;

    my $lock = _get_lock($name, $jobid, $where);

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
    my $lock = _get_lock($name, $jobid, $where // 'all');
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
    my $lock = _get_lock($name, $jobid, 'all');
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

sub barrier_create {
    my ($name, $jobid, $expected_jobs) = @_;
    return 0 unless $name && $jobid && $expected_jobs;
    my $barrier = _get_lock($name, $jobid, 'all');
    return 0 if $barrier;

    my $schema = OpenQA::Schema->singleton;
    $barrier = $schema->resultset('JobLocks')->create({name => $name, owner => $jobid, count => $expected_jobs});
    return 0 unless $barrier;
    return $barrier;
}

sub barrier_wait {
    my ($name, $jobid, $where, $check_dead_job) = @_;

    return -1 unless $name && $jobid;
    return -1 unless my $barrier = _get_lock($name, $jobid, $where);

    my $jobschema = OpenQA::Schema->singleton->resultset('Jobs');
    my @jobs = split ',', $barrier->locked_by // '';

    if ($check_dead_job) {
        my @related_ids = map { scalar $_->id } $barrier->owner->parents->all, $barrier->owner->children->all;
        my @results = map { $jobschema->find($_)->result } $jobid, @jobs, @related_ids;
        for my $result (@results) {
            next unless $final_states{$result};
            $barrier->delete;
            return -1;
        }
    }

    if (grep { $_ eq $jobid } @jobs) {
        return 1 if @jobs == $barrier->count;
        return 0;
    }

    push @jobs, $jobid;
    $barrier->update({locked_by => join(',', @jobs)});

    return 1 if @jobs == $barrier->count;
    return 0;
}

sub barrier_destroy {
    my ($name, $jobid, $where) = @_;
    return 0 unless $name && $jobid;
    my $barrier = _get_lock($name, $jobid, $where);
    return 0 unless $barrier;
    return $barrier->delete;
}

1;
