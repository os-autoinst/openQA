# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::DeveloperSessions;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

use Try::Tiny;
use OpenQA::Constants qw(WORKER_COMMAND_DEVELOPER_SESSION_START);
use OpenQA::Schema::Result::DeveloperSessions;
use OpenQA::WebSockets::Client;
use OpenQA::Log 'log_error';

sub register {
    my ($self, $job_id, $user_id) = @_;

    # create database entry for the session
    my $schema = $self->result_source->schema;
    my ($result, $worker_id, $is_session_already_existing) = $schema->txn_do(
        sub {
            # refuse if no worker assigned
            my $worker = $schema->resultset('Workers')->search({job_id => $job_id})->first;
            return unless ($worker);

            my $session = $self->find({job_id => $job_id});
            my $is_session_already_existing = defined($session);
            if ($is_session_already_existing) {
                # allow only one session per job
                return unless ($session->user_id eq $user_id);
            }
            else {
                # create a new session if none existed before
                $session = $self->create(
                    {
                        job_id => $job_id,
                        user_id => $user_id,
                    });

            }
            return ($session, $worker->id, $is_session_already_existing);
        });

    # inform the worker that a new the developer session has been started
    if ($result && !$is_session_already_existing) {
        # hope this IPC call isn't blocking too long (since the livehandler isn't preforking)
        my $client = OpenQA::WebSockets::Client->singleton;
        try {
            $client->send_msg($worker_id, WORKER_COMMAND_DEVELOPER_SESSION_START, $job_id);
        }
        catch {
            log_error("Unable to inform worker about developer session: $_");
        };
    }

    return $result;
}

sub unregister {
    my ($self, $job_id) = @_;
    # to keep track of the responsible developer, don't delete the database entry here
    # (it is deleted when the associated job is delete anyways)

    # however, we should cancel the job now
    return $self->result_source->schema->txn_do(
        sub {
            my $session = $self->find({job_id => $job_id}) or return 0;
            my $job = $session->job or return 0;
            return $job->cancel();
        });
}

1;
