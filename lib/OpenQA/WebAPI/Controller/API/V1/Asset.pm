# Copyright (C) 2015-2016 SUSE LLC
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
    my ($self) = @_;

    my $type = $self->param('type');
    my $name = $self->param('name');

    my $asset = $self->app->schema->resultset("Assets")->register($type, $name);

    my $status = 200;
    my $json   = {};
    if ($asset) {
        $json->{id} = $asset->id;
        $self->emit_event('openqa_asset_register', {id => $asset->id, type => $type, name => $name});
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
    for my $arg (qw(id type name)) {
        $args{$arg} = $self->stash($arg) if defined $self->stash($arg);
    }

    if (defined $args{id} && $args{id} !~ /^\d+$/) {
        $self->render(json => {}, status => 404);
        return;
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
    my ($self) = @_;

    my %args;
    for my $arg (qw(id type name)) {
        $args{$arg} = $self->stash($arg) if defined $self->stash($arg);
    }

    my %cond;
    my %attrs;

    if (defined $args{id}) {
        if ($args{id} !~ /^\d+$/) {
            $self->render(json => {}, status => 404);
            return;
        }
        $cond{id} = $args{id};
    }
    elsif (defined $args{type} && defined $args{name}) {
        $cond{name} = $args{name};
        $cond{type} = $args{type};
    }
    else {
        return;
    }

    my $asset = $self->app->schema->resultset("Assets")->search(\%cond, \%attrs);
    return unless $asset;
    my $rs = $asset->delete_all;
    $self->emit_event('openqa_asset_delete', \%args);

    $self->render(json => {count => $rs});
}

1;
# vim: set sw=4 et:
