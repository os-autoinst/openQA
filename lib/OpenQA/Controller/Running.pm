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

package OpenQA::Controller::Running;
use strict;
use warnings;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util 'b64_encode';
use JSON qw/encode_json decode_json/;
use OpenQA::Utils;
use OpenQA::Scheduler ();

sub init {
    my ($self) = @_;

    my $job = $self->app->schema->resultset("Jobs")->find($self->param('testid'));

    unless (defined $job && $job->worker_id) {
        $self->reply->not_found;
        return 0;
    }
    $self->stash('job', $job);

    1;
}

sub modlist {
    my $self = shift;
    return 0 unless $self->init();

    my $modinfo = $self->stash('job')->running_modinfo();
    if (defined $modinfo) {
        $self->render(json => $modinfo->{'modlist'});
    }
    else {
        $self->reply->not_found;
    }
}

sub status {
    my $self = shift;
    return 0 unless $self->init();

    my $job = $self->stash('job');
    my $workerid = $job->worker_id;
    my $results = { workerid => $workerid, state => $job->state };
    my $r = $job->modules->find({result => 'running'});
    $results->{'running'} = $r->name() if $r;

    if ($workerid) {
        $results->{interactive} = $job->worker->get_property('INTERACTIVE')//0;
        $results->{interactive_requested} = $job->worker->get_property('INTERACTIVE_REQUESTED')//0;
        $results->{stop_waitforneedle_requested} = $job->worker->get_property('STOP_WAITFORNEEDLE_REQUESTED')//0;
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
        my $stepid = scalar(@{$details});
        $self->redirect_to('edit_step', moduleid => $r->name(), stepid => $stepid);
    }
    else {
        $self->reply->not_found;
    }
}

sub livelog {
    my ($self) = @_;
    return 0 unless $self->init();
    my $job = $self->stash('job');
    my $worker = $job->worker;
    # tell worker to increase status updates rate for more responsive updates
    OpenQA::Scheduler::command_enqueue(
        workerid => $worker->id,
        command => 'livelog_start'
    );

    my $logfile = $worker->get_property('WORKER_TMPDIR').'/autoinst-log-live.txt';

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
        if ($size > 10*1024 && seek $log, -10*1024, 2) {
            # Discard one (probably) partial line
            my $dummy = <$log>;
        }
        while (defined(my $l = <$log>)) {
            $self->write("data: ".encode_json([$l])."\n\n");
        }
        seek $log, 0, 1;
    }

    # Now we set up a recurring timer to check for new lines from the
    # logfile and send them to the client, plus a utility function to
    # close the connection if anything goes wrong.
    my $id;
    my $close = sub {
        Mojo::IOLoop->remove($id);
        OpenQA::Scheduler::command_enqueue(
            workerid => $worker->id,
            command => 'livelog_stop'
        );
        $self->finish;
        close $log;
        return;
    };
    $id = Mojo::IOLoop->recurring(
        1 => sub {
            if (!$ino) {
                # log file was not yet opened
                return unless (open($log, '<', $logfile));
                $ino = (stat $logfile)[1];
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
                return $close->();
            }

            # If there's new data, read it all and send it out. Then
            # seek to the current position to reset EOF.
            if ($size < $st[7]) {
                $size = $st[7];
                my $lines = '';
                while (defined(my $l = <$log>)) {
                    $lines .= $l;
                }
                $self->write("data: ".encode_json([$lines])."\n\n");
                seek $log, 0, 1;
            }
        }
    );

    # If the client closes the connection, we can stop monitoring the
    # logfile.
    $self->on(
        finish => sub {
            Mojo::IOLoop->remove($id);
            OpenQA::Scheduler::command_enqueue(
                workerid => $worker->id,
                command => 'livelog_stop'
            );
        }
    );
}

sub streaming {
    my ($self) = @_;
    return 0 unless $self->init();

    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    $self->res->code(200);
    $self->res->headers->content_type('text/event-stream');

    my $lastfile = '';
    my $basepath = $self->stash('job')->worker->get_property('WORKER_TMPDIR');

    # Set up a recurring timer to send the last screenshot to the client,
    # plus a utility function to close the connection if anything goes wrong.
    my $id;
    my $close = sub {
        Mojo::IOLoop->remove($id);
        $self->finish;
        return;
    };

    $id = Mojo::IOLoop->recurring(
        0.3 => sub {
            my $newfile = readlink("$basepath/last.png")||'';
            if ($lastfile ne $newfile) {
                if ( !-l $newfile || !$lastfile ) {
                    my $data = file_content("$basepath/$newfile");
                    $self->write("data: data:image/png;base64,".b64_encode($data, '')."\n\n");
                    $lastfile = $newfile;
                }
                elsif (!-e $basepath.'backend.run') {
                    # Some browsers can't handle mpng (at least after reciving jpeg all the time)
                    my $data = file_content($self->app->static->file('images/suse-tested.png')->path);
                    $self->write("data: data:image/png;base64,".b64_encode($data, '')."\n\n");
                    $close->();
                }
            }
        }
    );

    $self->on(finish => sub { Mojo::IOLoop->remove($id) });
}

1;
# vim: set sw=4 et:
