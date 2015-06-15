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

package OpenQA::WebAPI::Controller::API::V1::Asset;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::IPC;

sub register {
    my $self = shift;

    my $type = $self->param('type');
    my $name = $self->param('name');

    my $ipc = OpenQA::IPC->ipc;
    my $id = $ipc->scheduler('asset_register', {type => $type, name => $name});

    my $status = 200;
    my $json   = {};
    if ($id) {
        $json->{id} = $id;
    }
    else {
        $status = 400;
    }
    $self->render(json => $json, status => $status);
}

sub list {
    my $self   = shift;
    my $schema = $self->app->schema;

    my $rs = $schema->resultset("Assets")->search();
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');
    $self->render(json => {assets => [$rs->all]});
}

sub get {
    my $self   = shift;
    my $schema = $self->app->schema;

    my %args;
    for my $arg (qw/id type name/) {
        $args{$arg} = $self->stash($arg) if defined $self->stash($arg);
    }

    my $rs = $schema->resultset("Assets")->search(\%args);
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    if ($rs && $rs->single) {
        $self->render(json => $rs->single, status => 200);
    }
    else {
        $self->render(json => {}, status => 404);
    }
}

sub delete {
    my $self = shift;

    my %args;
    for my $arg (qw/id type name/) {
        $args{$arg} = $self->stash($arg) if defined $self->stash($arg);
    }

    my $ipc = OpenQA::IPC->ipc;
    my $rs = $ipc->scheduler('asset_delete', \%args);

    $self->render(json => {count => $rs});
}

1;
# vim: set sw=4 et:
