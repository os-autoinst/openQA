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
use diagnostics;

# we need the critical fix for update
# see https://github.com/dbsrgits/dbix-class/commit/31160673f390e178ee347e7ebee1f56b3f54ba7a
use DBIx::Class 0.082801;

use DBIx::Class::ResultClass::HashRefInflator;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Schema::Result::JobDependencies;
use OpenQA::Utils 'log_debug';
use OpenQA::ResourceAllocator;

require Exporter;
our (@ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
@ISA    = qw(Exporter);
@EXPORT = qw(job_restart job_create);

sub schema { OpenQA::ResourceAllocator->instance->schema }

=head2 job_restart

=over

=item Arguments: SCALAR or ARRAYREF of Job IDs

=item Return value: ARRAY of new job ids

=back

Handle job restart by user (using API or WebUI). Job is only restarted when either running
or done. Scheduled jobs can't be restarted.

=cut
sub job_restart {
    my ($jobids) = @_ or die "missing name parameter\n";

    # first, duplicate all jobs that are either running or done
    my $jobs = schema->resultset("Jobs")->search(
        {
            id    => $jobids,
            state => [OpenQA::Jobs::Constants::EXECUTION_STATES, OpenQA::Jobs::Constants::FINAL_STATES],
        });

    my @duplicated;
    while (my $j = $jobs->next) {
        my $dup = $j->auto_duplicate;
        push @duplicated, $dup->{cluster_cloned} if $dup;
    }

    # then tell workers to abort
    $jobs = schema->resultset("Jobs")->search(
        {
            id    => $jobids,
            state => [OpenQA::Jobs::Constants::EXECUTION_STATES],
        });

    $jobs->search(
        {
            result => OpenQA::Jobs::Constants::NONE,
        }
    )->update(
        {
            result => OpenQA::Jobs::Constants::USER_RESTARTED,
        });

    while (my $j = $jobs->next) {
        log_debug("enqueuing abort for " . $j->id . " " . $j->worker_id);
        $j->worker->send_command(command => 'abort', job_id => $j->id);
    }
    return @duplicated;
}

1;
