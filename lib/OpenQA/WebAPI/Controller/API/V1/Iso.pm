# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::WebAPI::Controller::API::V1::Iso;
use Mojo::Base 'Mojolicious::Controller';

use OpenQA::Utils;
use OpenQA::IPC;

sub create {
    my $self = shift;
    my $ipc  = OpenQA::IPC->ipc;

    my $validation = $self->validation;
    $validation->required('DISTRI');
    $validation->required('VERSION');
    $validation->required('FLAVOR');
    $validation->required('ARCH');
    if ($validation->has_error) {
        my $error = "Error: missing parameters:";
        for my $k (qw/DISTRI VERSION FLAVOR ARCH/) {
            $self->app->log->debug(@{$validation->error($k)}) if $validation->has_error($k);
            $error .= ' ' . $k if $validation->has_error($k);
        }
        $self->res->message($error);
        return $self->rendered(400);
    }

    my $params = $self->req->params->to_hash;
    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    # restore URL encoded /
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;
    $self->emit_event('openqa_iso_create', \%params);

    my $ids = $ipc->scheduler('job_schedule_iso', \%params);
    my $cnt = scalar(@$ids);

    $self->app->log->debug("created $cnt jobs");
    $self->render(json => {count => $cnt, ids => $ids});
}

sub destroy {
    my $self = shift;
    my $iso  = $self->stash('name');
    my $ipc  = OpenQA::IPC->ipc;
    $self->emit_event('openqa_iso_delete', {iso => $iso});

    my $res = $ipc->scheduler('job_delete_by_iso', $iso);
    $self->render(json => {count => $res});
}

sub cancel {
    my $self = shift;
    my $iso  = $self->stash('name');
    my $ipc  = OpenQA::IPC->ipc;
    $self->emit_event('openqa_iso_cancel', {iso => $iso});

    my $res = $ipc->scheduler('job_cancel_by_iso', $iso, 0);
    $self->render(json => {result => $res});
}

1;
# vim: set sw=4 et:
