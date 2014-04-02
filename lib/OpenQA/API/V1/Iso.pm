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

package OpenQA::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller';
use openqa;
use Scheduler ();

sub create {
    my $self = shift;

    my $iso = $self->param('iso');
    my @tests = split(',', ($self->param('tests') || ''));
    for my $t (@tests) {
        if ($t !~ /^[a-zA-Z0-9+_-]+$/) {
            $self->res->message("invalid character in test name");
            return $self->rendered(400);
        }
    }
    unless ($iso) {
        $self->res->message("Missing iso parameter");
        return $self->rendered(400);
    }
    my $jobs = openqa::distri::generate_jobs($self->app->config, iso => $iso, requested_runs => \@tests);

    # XXX: take some attributes from the first job to guess what old jobs to
    # cancel. We should have distri object that decides which attributes are
    # relevant here.
    if ($jobs && $jobs->[0] && $jobs->[0]->{BUILD}) {
        my %cond;
        for my $k (qw/DISTRI VERSION FLAVOR ARCH/) {
            next unless $jobs->[0]->{$k};
            $cond{$k} = $jobs->[0]->{$k};
        }
        if (%cond) {
            Scheduler::job_cancel(\%cond);
        }
    }

    my $cnt = 0;
    for my $settings (@{$jobs||[]}) {
        my $prio = $settings->{PRIO};
        delete $settings->{PRIO};
        # create a new job with these parameters and count if successful
        my $id = Scheduler::job_create(%$settings);
        if ($id) {
            $cnt++;
            # change prio only if other than defalt prio
            if( $prio && $prio != 50 ) {
                Scheduler::job_set_prio(jobid => $id, prio => $prio);
            }
        }
    }
    $self->render(json => {count => $cnt});
}

sub destroy {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = Scheduler::job_delete($iso);
    $self->render(json => {count => $res});
}

sub cancel {
    my $self = shift;
    my $iso = $self->stash('name');

    my $res = Scheduler::job_cancel($iso);
    $self->render(json => {result => $res});
}

1;
# vim: set sw=4 et:
