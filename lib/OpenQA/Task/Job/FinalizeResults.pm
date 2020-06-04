# Copyright (C) 2020 SUSE LLC
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

package OpenQA::Task::Job::FinalizeResults;
use Mojo::Base 'Mojolicious::Plugin';

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(finalize_job_results => sub { _finalize_results($app, @_); });
    $app->minion->add_task(cleanup_job_results  => sub { _cleanup_results($app, @_); });
}

sub _finalize_results {
    my ($app, $minion_job, $job_id) = @_;
    my $guard = $app->minion->guard("finalize_job_results_for_$job_id", 86400);
    return $minion_job->finish('Blocked by another finalize job') unless $guard;

    my $job    = $app->schema->resultset('Jobs')->find({id => $job_id});
    my $errors = 0;

    for my $module ($job->modules_with_job_prefetched) {
        $errors++ if !$module->finalize_results;
    }

    $app->gru->enqueue(cleanup_job_results => [$job_id] => {delay => 60});

    if ($errors) {
        $minion_job->fail("Finalizing results of $errors modules failed");
    }
}

sub _cleanup_results {
    my ($app, $minion_job, $job_id) = @_;
    # This job must not run in parallel with _finalize_results()
    my $guard = $app->minion->guard("finalize_job_results_for_$job_id", 86400);
    return $minion_job->finish('Blocked by another finalize job') unless $guard;

    my $job = $app->schema->resultset('Jobs')->find({id => $job_id});

    for my $module ($job->modules_with_job_prefetched) {
        $module->cleanup_results;
    }
}

1;
