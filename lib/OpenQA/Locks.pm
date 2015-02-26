# Copyright (c) 2015 SUSE LINUX GmbH, Nuernberg, Germany.
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

package OpenQA::Locks;

use strict;
use warnings;

use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobLocks;
use OpenQA::Scheduler;

sub _get_lock {
    my ($name, $jobid) = @_;
    return unless defined $name && defined $jobid;
    my $schema = OpenQA::Scheduler::schema();
    my $job = $schema->resultset('Jobs')->single({id => $jobid});
    return unless $job;

    # We need to get owner of the lock
    # owner can be one of the parents or ourselves if we have no parent
    my $lock;
    my @maybeowners = map {$_->id} ($job->parents->all, $job);
    return $schema->resultset('JobLocks')->search({name => $name, owner => { -in => \@maybeowners} })->single;
}

# returns undef on error, 1 on have lock, 0 on try later (lock unavailable)
sub lock {
    my ($name, $jobid) = @_;
    my $lock = _get_lock($name, $jobid);

    # if no lock so far, there is no lock, return as locked
    return unless $lock;
    # lock is locked and not by us
    if ($lock->locked_by) {
        return if ($lock->locked_by->id != $jobid);
        return 1;
    }
    # we're using optimistic locking, if this succeded, we were first
    return 1 if ($lock->update({'locked_by' => $jobid}));
    return;
}

sub unlock {
    my ($name, $jobid) = @_;
    my $lock = _get_lock($name, $jobid);
    return unless $lock;
    # return if not locked
    return 1 unless $lock->locked_by;
    # return if not locked by us
    return unless ($lock->locked_by->id == $jobid);
    return 1 if ($lock->update({'locked_by' => undef}));
    return;
}

sub create {
    my ($name, $jobid) = @_;
    my $lock = _get_lock($name, $jobid);
    # nothing if lock already exist
    return if $lock;
    return unless defined $name && defined $jobid;

    # if no lock so far, there is no lock, create one as unlocked
    my $schema = OpenQA::Scheduler::schema();
    $lock = $schema->resultset('JobLocks')->create({name => $name, owner => $jobid});
    return unless $lock;
    return 1;
}

1;
