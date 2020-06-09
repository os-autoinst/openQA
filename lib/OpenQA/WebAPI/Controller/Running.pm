# Copyright (C) 2014-2020 SUSE LLC
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

package OpenQA::WebAPI::Controller::Running;
use Mojo::Base 'Mojolicious::Controller';

use Mojo::Util 'b64_encode';
use Mojo::File 'path';
use Mojo::JSON qw(encode_json decode_json);
use OpenQA::Constants qw(WORKER_COMMAND_LIVELOG_STOP WORKER_COMMAND_LIVELOG_START);
use OpenQA::Log qw(log_debug log_error);
use OpenQA::Utils;
use OpenQA::WebSockets::Client;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Try::Tiny;

sub init {
    my ($self, $page_name) = @_;

    my $job = $self->app->schema->resultset('Jobs')->find($self->param('testid'));
    unless (defined $job) {
        $self->reply->not_found;
        return 0;
    }

    # succeed if the job has a worker
    if (my $worker = $job->worker) {
        $self->stash({job => $job, worker => $worker});
        return 1;
    }

    # return the state as JSON for status route
    if ($page_name && $page_name eq 'status') {
        $self->render(json => {state => $job->state, result => $job->result});
        return 0;
    }

    # render a 404 error page for other routes
    my $test_name = $job->name;
    my $what      = $page_name ? "the page \"$page_name\"" : 'this route';
    $self->render_specific_not_found($page_name // 'Page not found',
        "The test $test_name has no worker assigned so $what is not available.");
    return 0;
}

sub status {
    my $self = shift;
    return 0 unless $self->init('status');

    my $job            = $self->stash('job');
    my $results        = {workerid => $job->worker_id, state => $job->state, result => $job->result};
    my $running_module = $job->modules->find({result => 'running'}, {order_by => {-desc => 't_updated'}, rows => 1});
    $results->{running} = $running_module->name if $running_module;
    $self->render(json => $results);
}

sub edit {
    my $self      = shift;
    my $page_name = 'Needle Editor';
    return 0 unless $self->init($page_name);

    my $job            = $self->stash('job');
    my $running_module = $job->modules->find({result => 'running'});
    return $self->render_specific_not_found(
        $page_name,
'The test has no currently running module so opening the needle editor is not possible. Likely results have not been uploaded yet so reloading the page might help.',
    ) unless ($running_module);

    my $details = $running_module->results->{details};
    my $stepid  = scalar(@{$details});
    return $self->render_specific_not_found(
        $page_name,
'The results for the currently running module have not been uploaded yet so opening the needle editor is not possible. Likely the upload is still in progress so reloading the page might help.',
    ) unless ($stepid);
    $self->redirect_to('edit_step', moduleid => $running_module->name(), stepid => $stepid);
}

sub streamtext {
    my ($self, $file_name, $start_hook, $close_hook) = @_;

    my $job    = $self->stash('job');
    my $worker = $job->worker;
    $start_hook ||= sub { };
    $close_hook ||= sub { };
    my $logfile = $worker->get_property('WORKER_TMPDIR') . "/$file_name";

    $start_hook->($worker, $job);
    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    my $res = $self->res;
    $res->code(200);
    $res->headers->content_type('text/event-stream');

    # Try to open the log file and keep the filehandle
    # if the open fails, continue, well check later
    my $log;
    my ($ino, $size);
    if (open($log, '<', $logfile)) {
        # Send the last 10KB of data from the logfile, so that
        # the client sees some data immediately
        $ino = (stat $logfile)[1];

        $size = -s $logfile;
        if ($size > 10 * 1024 && seek $log, -10 * 1024, 2) {
            # Discard one (probably) partial line
            my $dummy = <$log>;
        }
        while (defined(my $l = <$log>)) {
            $self->write("data: " . encode_json([$l]) . "\n\n");
        }
        seek $log, 0, 1;
    }

    # Check for new lines from the logfile using recurring timer
    # Setup utility function to close the connection if something goes wrong
    my $timer_id;
    my $close_connection = sub {
        Mojo::IOLoop->remove($timer_id);
        $close_hook->();
        $self->finish;
        close $log;
    };
    $timer_id = Mojo::IOLoop->recurring(
        1 => sub {
            if (!$ino) {
                # log file was not yet opened
                return unless open($log, '<', $logfile);
                $ino  = (stat $logfile)[1];
                $size = -s $logfile;
            }

            # Zero tolerance for any shenanigans with the logfile, such as
            # truncation, rotation, etc.
            my @st = stat $logfile;
            return $close_connection->() unless @st && $st[1] == $ino && $st[3] > 0 && $st[7] >= $size;

            # If there's new data, read it all and send it out. Then
            # seek to the current position to reset EOF.
            if ($size < $st[7]) {
                $size = $st[7];
                my $lines = '';
                while (defined(my $l = <$log>)) {
                    $lines .= $l;
                }
                $self->write("data: " . encode_json([$lines]) . "\n\n");
                seek $log, 0, 1;
            }
        });

    # Stop monitoring the logfile when the connection closes
    $self->on(
        finish => sub {
            Mojo::IOLoop->remove($timer_id);
            $close_hook->($worker, $job);
        });
}

sub livelog {
    my ($self) = @_;
    return 0 unless $self->init();
    $self->streamtext('autoinst-log-live.txt');
}

sub liveterminal {
    my ($self) = @_;
    return 0 unless $self->init();
    $self->streamtext('serial-terminal-live.txt');
}

sub streaming {
    my ($self) = @_;
    return 0 unless $self->init();

    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    my $res = $self->res;
    $res->code(200);
    $res->headers->content_type('text/event-stream');

    my $job_id    = $self->stash('job')->id;
    my $worker    = $self->stash('worker');
    my $worker_id = $worker->id;
    my $lastfile  = '';
    my $basepath  = $worker->get_property('WORKER_TMPDIR');

    # Set up a recurring timer to send the last screenshot to the client,
    # plus a utility function to close the connection if anything goes wrong.
    my $timer_id;
    my $close_connection = sub {
        Mojo::IOLoop->remove($timer_id);
        $self->finish;
    };
    $timer_id = Mojo::IOLoop->recurring(
        0.3 => sub {
            my $newfile = readlink("$basepath/last.png") || '';
            return if $lastfile eq $newfile;
            if (!-l $newfile || !$lastfile) {
                my $data = path($basepath, $newfile)->slurp;
                $self->write("data: data:image/png;base64," . b64_encode($data, '') . "\n\n");
                $lastfile = $newfile;
            }
            elsif (!-e $basepath . 'backend.run') {
                # Some browsers can't handle mpng (at least after reciving jpeg all the time)
                my $data = $self->app->static->file('images/suse-tested.png')->slurp;
                $self->write("data: data:image/png;base64," . b64_encode($data, '') . "\n\n");
                $close_connection->();
            }
        });

    # ask worker to create live stream
    log_debug('Asking the worker to start providing livestream');

    my $client = OpenQA::WebSockets::Client->singleton;
    $self->tx->once(
        finish => sub {
            Mojo::IOLoop->remove($timer_id);

            # skip if the worker is not present anymore or already working on a different job
            # note: This is of course not entirely race-free. The worker will ignore messages which
            #       are not relevant anymore. This is merely to keep those messages to a minimum.
            my $worker = OpenQA::Schema->singleton->resultset('Workers')->find($worker_id);
            return undef unless $worker;
            return undef unless defined $worker->job_id && $worker->job_id == $job_id;

            # ask worker to stop live stream
            log_debug("Asking worker $worker_id to stop providing livestream");
            try {
                $client->send_msg($worker_id, WORKER_COMMAND_LIVELOG_STOP, $job_id);
            }
            catch {
                log_error("Unable to ask worker to stop providing livestream: $_");
            };
        },
    );
    try {
        $client->send_msg($worker_id, WORKER_COMMAND_LIVELOG_START, $job_id);
    }
    catch {
        my $error = "Unable to ask worker $worker_id to start providing livestream: $_";
        $self->render(json => {error => $error}, status => 500);
        $close_connection->();
        log_error($error);
    };
}

1;
