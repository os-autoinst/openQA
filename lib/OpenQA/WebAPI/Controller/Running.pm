# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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

use constant IMAGE_STREAMING_INTERVAL => $ENV{OPENQA_IMAGE_STREAMING_INTERVAL} // 0.3;
use constant TEXT_STREAMING_INTERVAL => $ENV{OPENQA_TEXT_STREAMING_INTERVAL} // 1.0;

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
    my $what = $page_name ? "the page \"$page_name\"" : 'this route';
    $self->render_specific_not_found($page_name // 'Page not found',
        "The test $test_name has no worker assigned so $what is not available.");
    return 0;
}

sub status {
    my $self = shift;
    return 0 unless $self->init('status');

    my $job = $self->stash('job');
    my $results = {workerid => $job->worker_id, state => $job->state, result => $job->result};
    my $running_module = $job->modules->find({result => 'running'}, {order_by => {-desc => 't_updated'}, rows => 1});
    $results->{running} = $running_module->name if $running_module;
    $self->render(json => $results);
}

sub edit {
    my $self = shift;
    my $page_name = 'Needle Editor';
    return 0 unless $self->init($page_name);

    my $job = $self->stash('job');
    my $running_module = $job->modules->find({result => 'running'});
    return $self->render_specific_not_found(
        $page_name,
'The test has no currently running module so opening the needle editor is not possible. Likely results have not been uploaded yet so reloading the page might help.',
    ) unless ($running_module);

    my $details = $running_module->results->{details};
    my $stepid = scalar(@{$details});
    return $self->render_specific_not_found(
        $page_name,
'The results for the currently running module have not been uploaded yet so opening the needle editor is not possible. Likely the upload is still in progress so reloading the page might help.',
    ) unless ($stepid);
    $self->redirect_to('edit_step', moduleid => $running_module->name(), stepid => $stepid);
}

sub streamtext {
    my ($self, $file_name, $start_hook, $close_hook) = @_;

    my $job = $self->stash('job');
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
        TEXT_STREAMING_INTERVAL() => sub {
            if (!$ino) {
                # log file was not yet opened
                return unless open($log, '<', $logfile);
                $ino = (stat $logfile)[1];
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

    my $job_id = $self->stash('job')->id;
    my $worker = $self->stash('worker');
    my $worker_id = $worker->id;
    my $basepath = $worker->get_property('WORKER_TMPDIR');
    return $self->render_specific_not_found("Live image for job $job_id", "No tempdir for worker $worker_id set.")
      unless $basepath;

    # send images via server-sent events
    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    my $res = $self->res;
    $res->code(200);
    $res->headers->content_type('text/event-stream');

    # setup a function to stop streaming again
    my $timer_id;
    my $close_connection = sub {
        Mojo::IOLoop->remove($timer_id);
        $self->finish;
    };

    # setup a recurring timer to send the last screenshot to the client
    my $last_png = "$basepath/last.png";
    my $backend_run_file = "$basepath/backend.run";
    my $lastfile = '';
    $timer_id = Mojo::IOLoop->recurring(
        IMAGE_STREAMING_INTERVAL() => sub {
            my $newfile = readlink($last_png) || '';
            return if $lastfile eq $newfile;

            my ($file, $close);
            if (!-l $newfile || !$lastfile) {
                $file = path($basepath, $newfile);
                $lastfile = $newfile;
            }
            elsif (!-e $backend_run_file) {
                # show special image when backend has terminated
                $file = $self->app->static->file('images/suse-tested.png');
                $close = 1;
            }

            my $data_base64 = eval { b64_encode(path($basepath, $newfile)->slurp, '') };
            if (my $error = $@) {
                # log the error as server-sent events message and close the connection
                # note: This should be good enough for debugging on the client-side. The client will re-attempt
                #       streaming. Avoid logging on the server-side here to avoid flooding the log for this
                #       non-critical problem.
                chomp $error;
                $self->write("data: Unable to read image: $error\n\n", $close_connection);
            }
            else {
                $self->write("data: data:image/png;base64,$data_base64\n\n", $close ? $close_connection : undef);
            }
        });

    # ask worker to create live stream
    log_debug("Asking the worker $worker_id to start providing livestream for job $job_id");

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
            log_debug("Asking worker $worker_id to stop providing livestream for job $job_id");
            try {
                $client->send_msg($worker_id, WORKER_COMMAND_LIVELOG_STOP, $job_id);
            }
            catch {
                log_error("Unable to ask worker $worker_id to stop providing livestream for $job_id: $_");
            };
        },
    );
    try {
        $client->send_msg($worker_id, WORKER_COMMAND_LIVELOG_START, $job_id);
    }
    catch {
        my $error = "Unable to ask worker $worker_id to start providing livestream for $job_id: $_";
        $self->write("data: $error\n\n", $close_connection);
        log_error($error);
    };
}

1;
