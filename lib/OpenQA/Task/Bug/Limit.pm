# Copyright (C) 2020-2021 SUSE LLC
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

package OpenQA::Task::Bug::Limit;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Time::Seconds;

sub register ($self, $app) { $app->minion->add_task(limit_bugs => \&_limit) }

sub _limit ($job) {
    my $app = $job->app;

    # prevent multiple limit_bugs tasks to run in parallel
    return $job->finish('Previous limit_bugs job is still active')
      unless my $guard = $app->minion->guard('limit_bugs_task', ONE_DAY);

    # prevent multiple limit_* tasks to run in parallel
    return $job->retry({delay => 60})
      unless my $limit_guard = $app->minion->guard('limit_tasks', ONE_DAY);

    # cleanup entries in the bug table that are not referenced from any comments
    my $bugrefs = $app->schema->resultset('Comments')->referenced_bugs;
    my %cleaned;
    for my $bug ($app->schema->resultset('Bugs')->all) {
        next if defined $bugrefs->{$bug->bugid};
        $bug->delete;
        $cleaned{$bug->id} = $bug->bugid;
    }
    $app->emit_event('openqa_bugs_cleaned', {deleted => scalar(keys(%cleaned))});
    $job->note(bugs_cleaned => \%cleaned);
}

1;
