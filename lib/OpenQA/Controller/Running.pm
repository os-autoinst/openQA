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
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util 'b64_encode';
use Mojo::UserAgent;
import JSON;
use openqa;
use Mojolicious::Static;
use Scheduler ();
use Data::Dump qw(dd);

sub init {
    my $self = shift;
    my $job = Scheduler::job_get($self->param('testid'));

    unless (defined $job) {
        $self->render_not_found;
        return 0;
    }
    $self->stash('job', $job);

    my $testdirname = $job->{'settings'}->{'NAME'};
    $self->stash('testdirname', $testdirname);

    my $basepath = running_log($testdirname);
    $self->stash('basepath', $basepath);
    my $workerid = $job->{'worker_id'};
    $self->stash('workerid', $workerid);
    my $worker = Scheduler::worker_get($workerid);
    my $workerport = $worker->{properties}->{WORKER_PORT};
    my $workerurl = $worker->{properties}->{WORKER_IP} . ':' . $workerport;
    $self->stash('workerurl', $workerurl);

    if ($basepath eq '') {
        $self->render_not_found;
        return 0;
    }

    1;
}

sub modlist {
    my $self = shift;
    return 0 unless $self->init();

    my $results = test_result($self->stash('testdirname'));
    my $modinfo = get_running_modinfo($results);
    if (defined $modinfo) {
        $self->render(json => $modinfo->{'modlist'});
    }
    else {
        $self->render_not_found;
    }
}

sub status {
    my $self = shift;
    return 0 unless $self->init();

    my $results = test_result($self->stash('testdirname'));
    delete $results->{'testmodules'};
    delete $results->{'distribution'};
    $self->render(json => $results);
}

sub edit {
    my $self = shift;
    return 0 unless $self->init();

    my $results = test_result($self->stash('testdirname'));
    my $moduleid = $results->{'running'};
    my $module = test_result_module($results->{'testmodules'}, $moduleid);
    if ($module) {
        my $stepid = scalar(@{$module->{'details'}});
        $self->redirect_to('edit_step', moduleid => $moduleid, stepid => $stepid);
    }
    else {
        $self->render_not_found;
    }
}

sub livelog {
    my ($self) = @_;
    return 0 unless $self->init();
    # tell worker to increase status updates rate for more responsive updates
    Scheduler::command_enqueue(workerid => $self->stash('workerid'), command => 'livelog_start');

    my $logfile = $self->stash('basepath').'autoinst-log-live.txt';

    # We'll open the log file and keep the filehandle.
    my $log;
    unless (open($log, '<', $logfile)) {
        $self->render_not_found;
        return;
    }
    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    $self->res->code(200);
    $self->res->headers->content_type("text/event-stream");

    # Send the last 10KB of data from the logfile, so that
    # the client sees some data immediately
    my $ino = (stat $logfile)[1];

    my $size = -s $logfile;
    if ($size > 10*1024 && seek $log, -10*1024, 2) {
        # Discard one (probably) partial line
        my $dummy = <$log>;
    }
    while (defined(my $l = <$log>)) {
        $self->write("data: ".encode_json([$l])."\n\n");
    }
    seek $log, 0, 1;

    # Now we set up a recurring timer to check for new lines from the
    # logfile and send them to the client, plus a utility function to
    # close the connection if anything goes wrong.
    my $id;
    my $close = sub {
        Mojo::IOLoop->remove($id);
        Scheduler::command_enqueue(workerid => $self->stash('workerid'), command => 'livelog_stop');
        $self->finish;
        close $log;
        return;
    };
    $id = Mojo::IOLoop->recurring(
        1 => sub {
            my @st = stat $logfile;

            # Zero tolerance for any shenanigans with the logfile, such as
            # truncation, rotation, etc.
            unless (@st
                && $st[1] == $ino
                &&$st[3] > 0
                && $st[7] >= $size)
            {
                return $close->();
            }

            # If there's new data, read it all and send it out. Then
            # seek to the current position to reset EOF.
            if ($size < $st[7]) {
                $size = $st[7];
                while (defined(my $l = <$log>)) {
                    $self->write("data: ".encode_json([$l])."\n\n");
                }
                seek $log, 0, 1;
            }
        }
    );

    # If the client closes the connection, we can stop monitoring the
    # logfile.
    $self->on(
        finish => sub {
            Mojo::IOLoop->remove($id);
            Scheduler::command_enqueue(
                workerid => $self->stash('workerid'),
                command => 'livelog_stop'
            );
        }
    );
}

sub streaming {
    my $self = shift;
    return 0 unless $self->init();

    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    $self->res->code(200);
    $self->res->headers->content_type('text/event-stream');

    my $lastfile = '';
    my $basepath = $self->stash('basepath');

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
