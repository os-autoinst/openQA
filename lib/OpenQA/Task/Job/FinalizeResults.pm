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

package OpenQA::Task::Job::FinalizeResults;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use OpenQA::Jobs::Constants 'CANCELLED';
use Time::Seconds;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(finalize_job_results => \&_finalize_results);
}

sub _finalize_results {
    my ($minion_job, $openqa_job_id, $carried_over) = @_;

    my $app = $minion_job->app;
    return $minion_job->fail('No job ID specified.') unless defined $openqa_job_id;
    return $minion_job->retry({delay => 30})
      unless my $guard = $app->minion->guard("process_job_results_for_$openqa_job_id", ONE_DAY);

    # try to finalize each
    my $openqa_job = $app->schema->resultset('Jobs')->find($openqa_job_id);
    return $minion_job->finish("Job $openqa_job_id does not exist.") unless $openqa_job;
    my %failed_to_finalize;
    for my $module ($openqa_job->modules_with_job_prefetched) {
        eval { $module->finalize_results; };
        if (my $error = $@) { $failed_to_finalize{$module->name} = $error; }
    }

    # record failed modules
    if (keys %failed_to_finalize) {
        my $count = scalar keys %failed_to_finalize;
        $minion_job->note(failed_modules => \%failed_to_finalize);
        $minion_job->fail("Finalizing results of $count modules failed");
    }
    return if $openqa_job->state eq CANCELLED;
    return if $carried_over;
    my $key = 'job_done_hook_' . $openqa_job->result;
    if (my $hook = $ENV{'OPENQA_' . uc $key} // $app->config->{hooks}->{lc $key}) {
        my $timeout      = $ENV{OPENQA_JOB_DONE_HOOK_TIMEOUT}      // '5m';
        my $kill_timeout = $ENV{OPENQA_JOB_DONE_HOOK_KILL_TIMEOUT} // '30s';
        my $ret          = _done_hook_new_issue($openqa_job, $hook, $timeout, $kill_timeout);
        $minion_job->note(hook_cmd => $hook, hook_result => $ret);
    }
}

sub _done_hook_new_issue ($openqa_job, $hook, $timeout, $kill_timeout) {
    my $id = $openqa_job->id;
    qx{timeout --kill-after="$kill_timeout" "$timeout" $hook $id};
}

1;
