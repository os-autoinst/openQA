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

package OpenQA::Running;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::Util 'b64_encode';
use Mojo::UserAgent;
import JSON;
use openqa;
use Mojolicious::Static;
use Scheduler ();

sub init {
    my $self = shift;
    my $job = Scheduler::job_get($self->param('testid'));

    unless (defined $job) {
        $self->render_not_found;
        return 0;
    }
    my $WORKER_PORT_START = 20003;
    $self->stash('job', $job);

    my $testdirname = $job->{'settings'}->{'NAME'};
    $self->stash('testdirname', $testdirname);

    my $basepath = running_log($testdirname);
    $self->stash('basepath', $basepath);
    my $workerid = $job->{'worker_id'};
    my $worker = Scheduler::worker_get($workerid);
    my $workerport = $worker->{'instance'} * 10 + $WORKER_PORT_START;
    my $workerurl = $worker->{'host'} . ':' . $workerport;
    $self->stash('workerurl', $workerurl);
    $self->stash('jobpassword', $job->{'settings'}->{'CONNECT_PASSWORD'});

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

    $self->render_later;
    Mojo::IOLoop->stream($self->tx->connection)->timeout(900);
    $self->res->code(200);
    $self->res->headers->content_type("text/event-stream");

    # prepare connection to worker and get first batch
    my $livelogurl = $self->stash('workerurl') . '/live_log?connect_password=' . $self->stash('jobpassword');
    my $ua = Mojo::UserAgent->new;
    my $tx = $ua->get($livelogurl);
    if (!$tx->success) {
        my $err = $tx->error;
        $self->write('data: '.encode_json([sprintf("ERROR: (%d) %s\n", $err->{'code'}||-1, $err->{'message'})])."\n\n");
        return;
    }
    # now first read from the start and get actual position
    $self->write('data: '.encode_json([$tx->res->body])."\n\n");
    my $pos = $tx->res->headers->header('X-New-Offset');

    # Now we set up a recurring timer to check for new lines from the
    # worker and send them to the client, plus a utility function to
    # close the connection if anything goes wrong.
    my $id;
    my $close = sub {
        Mojo::IOLoop->remove($id);
        $self->finish;
        return;
    };
    $id = Mojo::IOLoop->recurring(
        1 => sub {
            $tx = $ua->get($livelogurl . '&offset=' . $pos);
            if (!$tx->success) {
                my $err = $tx->error;
                $self->write('data: '.encode_json([sprintf("ERROR: (%d) %s\n", $err->{'code'}||-1, $err->{'message'})])."\n\n");
                return $close->();
            }
            $self->write('data: '.encode_json([$tx->res->body])."\n\n");
            $pos = $tx->res->headers->header('X-New-Offset');
        }
    );

    # If the client closes the connection, we can stop polling worker
    $self->on(
        finish => sub {
            Mojo::IOLoop->remove($id);
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
