# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Controller::Running;
use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util 'b64_encode';
use Mojo::File 'path';
use Cpanel::JSON::XS qw(encode_json decode_json);
use OpenQA::Utils;
use OpenQA::IPC;
use OpenQA::Schema::Result::Jobs;

sub init {
    my ($self) = @_;

    my $job = $self->app->schema->resultset("Jobs")->find($self->param('testid'));

    unless (defined $job) {
        $self->reply->not_found;
        return 0;
    }
    if (!$job->worker) {
        $self->render(json => {state => $job->state});
        return 0;
    }
    $self->stash('job', $job);

    1;
}

sub status {
    my $self = shift;
    return 0 unless $self->init();

    my $job      = $self->stash('job');
    my $workerid = $job->worker_id;
    my $results  = {workerid => $workerid, state => $job->state};
    my $r        = $job->modules->find({result => 'running'});
    $results->{running} = $r->name() if $r;

    if ($workerid) {
        $results->{interactive}                  = $job->worker->get_property('INTERACTIVE') // 0;
        $results->{stop_waitforneedle_requested} = $job->worker->get_property('STOP_WAITFORNEEDLE_REQUESTED') // 0;
    }

    $results->{needinput} = $results->{state} eq OpenQA::Schema::Result::Jobs::WAITING ? 1 : 0;
    $self->render(json => $results);
}

sub edit {
    my $self = shift;
    return 0 unless $self->init();

    my $job = $self->stash('job');
    my $r = $job->modules->find({result => 'running'});

    if ($r) {
        my $details = $r->details();
        my $stepid  = scalar(@{$details});
        $self->redirect_to('edit_step', moduleid => $r->name(), stepid => $stepid);
    }
    else {
        $self->reply->not_found;
    }
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
    $self->res->code(200);
    $self->res->headers->content_type("text/event-stream");

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

    # Now we set up a recurring timer to check for new lines from the
    # logfile and send them to the client, plus a utility function to
    # close the connection if anything goes wrong.
    my $id;
    my $doclose = sub {
        Mojo::IOLoop->remove($id);
        $close_hook->();
        $self->finish;
        close $log;
        return;
    };
    $id = Mojo::IOLoop->recurring(
        1 => sub {
            if (!$ino) {
                # log file was not yet opened
                return unless (open($log, '<', $logfile));
                $ino  = (stat $logfile)[1];
                $size = -s $logfile;
            }
            my @st = stat $logfile;

            # Zero tolerance for any shenanigans with the logfile, such as
            # truncation, rotation, etc.
            unless (@st
                && $st[1] == $ino
                && $st[3] > 0
                && $st[7] >= $size)
            {
                return $doclose->();
            }

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

    # If the client closes the connection, we can stop monitoring the
    # logfile.
    $self->on(
        finish => sub {
            Mojo::IOLoop->remove($id);
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
    my $ipc = OpenQA::IPC->ipc;

    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    $self->res->code(200);
    $self->res->headers->content_type('text/event-stream');

    my $job      = $self->stash('job');
    my $worker   = $job->worker;
    my $lastfile = '';
    my $basepath = $worker->get_property('WORKER_TMPDIR');

    # Set up a recurring timer to send the last screenshot to the client,
    # plus a utility function to close the connection if anything goes wrong.
    my $id;
    my $doclose = sub {
        Mojo::IOLoop->remove($id);
        $self->finish;
        return;
    };

    $id = Mojo::IOLoop->recurring(
        0.3 => sub {
            my $newfile = readlink("$basepath/last.png") || '';
            if ($lastfile ne $newfile) {
                if (!-l $newfile || !$lastfile) {
                    my $data = path($basepath, $newfile)->slurp;
                    $self->write("data: data:image/png;base64," . b64_encode($data, '') . "\n\n");
                    $lastfile = $newfile;
                }
                elsif (!-e $basepath . 'backend.run') {
                    # Some browsers can't handle mpng (at least after reciving jpeg all the time)
                    my $data = $self->app->static->file('images/suse-tested.png')->slurp;
                    $self->write("data: data:image/png;base64," . b64_encode($data, '') . "\n\n");
                    $doclose->();
                }
            }
        });

    # ask worker to create live stream
    OpenQA::Utils::log_debug('Asking the worker to start providing livestream');

    $self->tx->once(
        finish => sub {
            Mojo::IOLoop->remove($id);
            # ask worker to stop live stream
            OpenQA::Utils::log_debug('Asking the worker to stop providing livestream');
            $ipc->websockets('ws_send', $worker->id, 'livelog_stop', $job->id);
        },
    );

    $ipc->websockets('ws_send', $worker->id, 'livelog_start', $job->id);
}

1;
# vim: set sw=4 et:
