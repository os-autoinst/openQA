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

package OpenQA::Controller::API::V1::Asset;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::Scheduler ();
use Data::Dump qw(pp);

sub register {
    my $self = shift;

    my $type = $self->param('type');
    my $name = $self->param('name');

    my $rs = OpenQA::Scheduler::asset_register(type => $type, name => $name);

    my $status;
    my $json = {};
    if ($rs) {
        $json->{id} = $rs->id;
    }
    else {
        $status = 400;
    }
    $self->render(json => $json, status => $status);
}

sub list {
    my $self = shift;

    my $rs = OpenQA::Scheduler::asset_list();
    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    $self->render(json => { assets => [ $rs->all() ] } );
}

sub get {
    my $self = shift;

    my %args;
    for my $arg (qw/id type name/) {
        $args{$arg} = $self->stash($arg);
    }

    my $rs = OpenQA::Scheduler::asset_get(%args);

    $rs->result_class('DBIx::Class::ResultClass::HashRefInflator');

    my $status;
    my $json = $rs->single();
    unless ($json) {
        $status = 404;
        $json = {};
    }
    $self->render(json => $json, status => $status );
}

sub delete {
    my $self = shift;

    my %args;
    for my $arg (qw/id type name/) {
        $args{$arg} = $self->stash($arg);
    }

    my $rs = OpenQA::Scheduler::asset_delete(%args);

    my $status;
    my $json = {};
    if ($rs) {
        $json->{count} = int($rs);
    }
    else {
        $status = 400;
    }
    $self->render(json => $json, status => $status);
}

1;
# vim: set sw=4 et:
