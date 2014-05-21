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

package OpenQA::Schedule;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub _stash_back{
    my $self = shift;
    my $back = $self->param('back')||'';

    if ($back eq 'results') {
        $back = $self->url_for('tests');
    }
    elsif ($back eq 'details') {
        $back = $self->url_for('test', 'testid' => $self->param('testid'));
    }
    else {
        $back = $self->req->headers->referrer;
    }
    $self->stash('back', $back);
}

sub cancel{
    my $self = shift;
    my $name = $self->param('testid');

    $self->render(json => {count => Scheduler::job_cancel($name), id => $name});
}

sub restart{
    my $self = shift;
    my $name = $self->param('testid');

    my @ids = Scheduler::job_restart($name);
    if (@ids) {
        my $code = 'duplicated ';
        for my $id (@ids) {
            $code .= $self->link_to($id => $self->url_for('test', 'testid' => $id));
        }
        $self->flash(code => $code);
    }

    _stash_back($self);
}

sub setpriority{
    my $self = shift;
    my $name = $self->param('testid');
    my $priority = $self->param('priority');

    my $job = Scheduler::job_get($name);
    Scheduler::job_set_prio( prio=>$priority, jobid=>$job->{id} );

    $self->render(json => { id => $job->{id}, priority => $priority});
}

1;
# vim: set sw=4 et:
