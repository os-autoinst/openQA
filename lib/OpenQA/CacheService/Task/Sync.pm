# Copyright (C) 2018-2019 SUSE LLC
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

package OpenQA::CacheService::Task::Sync;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::URL;

sub register {
    my ($self, $app) = @_;

    $app->minion->add_task(cache_tests => \&_cache_tests);
}

sub _cache_tests {
    my ($job, $from, $to) = @_;

    my $app = $job->app;
    my $log = $app->log;

    my $lock = $job->info->{notes}{lock};
    return $job->finish unless defined $from && defined $to && defined $lock;
    my $guard = $app->progress->guard($lock);
    unless ($guard) {
        $job->note(output => 'Sync was already requested by another job');
        return $job->finish(0);
    }

    my $job_prefix = "[Job #" . $job->id . "]";
    $log->debug("$job_prefix Sync: $from to $to");

    my @cmd = (qw(rsync -avHP), "$from/", qw(--delete), "$to/tests/");
    $log->debug("$job_prefix Calling " . join(' ', @cmd));
    my $output = `@cmd`;
    my $status = $? >> 8;
    $job->finish($status);
    $job->note(output => $output);
    $log->debug("$job_prefix Finished: $status");
}

1;

=encoding utf-8

=head1 NAME

OpenQA::CacheService::Task::Sync - Cache Service task Sync

=head1 SYNOPSIS

    plugin 'OpenQA::CacheService::Task::Sync';

=head1 DESCRIPTION

OpenQA::CacheService::Task::Sync is the task that minions of the OpenQA Cache Service
are executing to handle the tests and needles syncing.

=cut
