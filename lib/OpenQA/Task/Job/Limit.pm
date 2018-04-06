# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Task::Job::Limit;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(limit_results_and_logs => sub { _limit($app, @_) });
}

sub _limit {
    my ($app, $job) = @_;

    my $groups = $app->db->resultset('JobGroups');
    while (my $group = $groups->next) {
        my $important_builds = $group->important_builds;
        for my $job (@{$group->find_jobs_with_expired_results($important_builds)}) {
            $job->delete;
        }
        for my $job (@{$group->find_jobs_with_expired_logs($important_builds)}) {
            $job->delete_logs;
        }
    }
}


1;
