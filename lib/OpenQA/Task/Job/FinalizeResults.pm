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
    $app->minion->add_task(finalize_job_results => \&_finalize_results);
}

sub _finalize_results {
    my ($minion_job, $openqa_job_id) = @_;

    my $app = $minion_job->app;
    return $minion_job->fail('No job ID specified.') unless defined $openqa_job_id;
    return $minion_job->finish("A finalize_job_results job for $openqa_job_id is already active")
      unless my $guard = $app->minion->guard("finalize_job_results_for_$openqa_job_id", 86400);

    # try to finalize each
    my $openqa_job = $app->schema->resultset('Jobs')->find($openqa_job_id);
    return $minion_job->fail("Job $openqa_job_id does not exist.") unless $openqa_job;
    my %failed_to_finalize;
    for my $module ($openqa_job->modules_with_job_prefetched) {
        eval { $module->finalize_results; };
        if (my $error = $@) { $failed_to_finalize{$module->name} = $error; }
    }

    # record failed modules
    if (%failed_to_finalize) {
        my $count = scalar keys %failed_to_finalize;
        $minion_job->note(failed_modules => \%failed_to_finalize);
        $minion_job->fail("Finalizing results of $count modules failed");
    }
}

1;
