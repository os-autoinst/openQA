# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Scheduler::Controller::API;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Schema;
use OpenQA::Jobs::Constants;
use OpenQA::Utils qw(log_info log_warning);
use Try::Tiny;

sub wakeup {
    my $self = shift;
    OpenQA::Scheduler::wakeup();
    $self->render(text => 'ok');
}

sub report_stale_jobs {
    my $self = shift;

    # validate job IDs
    my $json = $self->req->json;
    use Data::Dumper;
    print("json: " . Dumper($json) . "\n");
    my $job_ids = ref($json) eq 'HASH' ? $json->{job_ids} : [];
    if (ref($job_ids) ne 'ARRAY' || !@$job_ids) {
        return $self->render(text => 'no job IDs specified', status => 400);
    }
    for my $job_id (@$job_ids) {
        return $self->render(text => 'invalid job_id', status => 400) if $job_id !~ /^\d+$/;
    }

    # set the status to incomplete and duplicate
    my $schema = OpenQA::Schema->singleton;
    try {
        $schema->txn_do(
            sub {
                my $stale_jobs = $schema->resultset('Jobs')->search(
                    {
                        id    => {-in => $job_ids},
                        state => {-in => [OpenQA::Jobs::Constants::EXECUTION_STATES]},
                    });
                for my $job ($stale_jobs->all) {
                    $job->done(result => OpenQA::Jobs::Constants::INCOMPLETE);
                    if (my $res = $job->auto_duplicate) {
                        log_warning(sprintf('Dead job %d aborted and duplicated %d', $job->id, $res->id));
                    }
                    else {
                        log_warning(sprintf('Dead job %d aborted as incomplete', $job->id));
                    }
                }
            });
    }
    catch {
        log_info("Failed to incomplete and duplicate dead jobs: $_");
    };

    $self->render(text => 'ok');
}

1;
