# Copyright (C) 2021 SUSE LLC
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

package OpenQA::Task::Job::ArchiveResults;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use Time::Seconds;

sub register ($self, $app, @args) {
    $app->minion->add_task(archive_job_results => \&_archive_results);
}

sub _archive_results ($minion_job, @args) {
    my ($openqa_job_id) = @args;
    my $app = $minion_job->app;
    return $minion_job->fail('No job ID specified.') unless defined $openqa_job_id;

    # FIXME: Should we ensure that the job results are finalized?
    # FIXME: Should we take care of possible interference with cleanup task?
    # FIXME: This breaks jobs currently loading the results tab. I suppose we have to live
    #        with it.

    return $minion_job->retry({delay => 60})
      unless my $guard1 = $app->minion->guard('archiving_results', ONE_DAY, {limit => 5});
    return $minion_job->retry({delay => 30})
      unless my $guard2 = $app->minion->guard("finalize_job_results_for_$openqa_job_id", ONE_DAY);

    my $openqa_job = $app->schema->resultset('Jobs')->find($openqa_job_id);
    return $minion_job->finish("Job $openqa_job_id does not exist.") unless $openqa_job;
    $minion_job->note(archived_path => $openqa_job->archive);
}

1;
