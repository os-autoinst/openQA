# Copyright (c) 2017-2018 SUSE LINUX GmbH, Nuernberg, Germany.
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

package OpenQA::Resource::Jobs;

use strict;
use warnings;

use OpenQA::Jobs::Constants;
use OpenQA::Schema;
use OpenQA::Utils 'log_debug';
use Exporter 'import';

our @EXPORT_OK = qw(job_restart);

=head2 job_restart

=over

=item Arguments: SCALAR or ARRAYREF of Job IDs

=item Return value: ARRAY of new job ids

=back

Handle job restart by user (using API or WebUI). Job is only restarted when either running
or done. Scheduled jobs can't be restarted.

=cut
sub job_restart {
    my ($jobids, $warnings) = @_ or die "missing name parameter\n";

    # duplicate all jobs that are either running or done
    my $schema = OpenQA::Schema->singleton;
    my $jobs   = $schema->resultset("Jobs")->search(
        {
            id    => $jobids,
            state => [OpenQA::Jobs::Constants::EXECUTION_STATES, OpenQA::Jobs::Constants::FINAL_STATES],
        });
    my @duplicated;
    while (my $job = $jobs->next) {
        my $missing_assets;
        if (defined $warnings && scalar @{$missing_assets = $job->missing_assets}) {
            my $job_id = $job->id;
            push(@$warnings, "Job $job_id misses the following assets: " . join(', ', @$missing_assets));
        }
        my $dup = $job->auto_duplicate;
        push @duplicated, $dup->{cluster_cloned} if $dup;
    }

    # abort running jobs
    my $running_jobs = $schema->resultset("Jobs")->search(
        {
            id    => $jobids,
            state => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        });
    $running_jobs->search({result => OpenQA::Jobs::Constants::NONE})
      ->update({result => OpenQA::Jobs::Constants::USER_RESTARTED});
    while (my $j = $running_jobs->next) {
        $j->calculate_blocked_by;
        $j->abort;
    }

    return @duplicated;
}

1;
