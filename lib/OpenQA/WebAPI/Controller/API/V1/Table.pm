# Copyright (C) 2014 SUSE Linux Products GmbH
#           (C) 2015 SUSE LLC
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

package OpenQA::WebAPI::Controller::API::V1::Table;
use Mojo::Base 'Mojolicious::Controller';

use Try::Tiny;

my %tables = (
    Machines => {
        keys => [['id'], ['name'],],
        cols     => ['id',   'name', 'backend', 'description'],
        required => ['name', 'backend'],
        defaults => {description => undef},
    },
    TestSuites => {
        keys => [['id'], ['name'],],
        cols     => ['id', 'name', 'description'],
        required => ['name'],
        defaults => {description => undef},
    },
    Products => {
        keys => [['id'], ['distri', 'version', 'arch', 'flavor'],],
        cols     => ['id',     'distri',  'version', 'arch', 'flavor', 'description'],
        required => ['distri', 'version', 'arch',    'flavor'],
        defaults => {description => "", name => ""},
    },
);


sub list {
    my ($self) = @_;

    my $table = $self->param("table");
    my %search;

    for my $key (@{$tables{$table}->{keys}}) {
        my $have = 1;
        for my $par (@$key) {
            $have &&= $self->param($par);
        }
        if ($have) {
            for my $par (@$key) {
                $search{$par} = $self->param($par);
            }
        }
    }

    my @result;
    eval {
        my $rs = $self->db->resultset($table);
        @result = %search ? $rs->search(\%search) : $rs->all;
    };
    my $error = $@;
    if ($error) {
        return $self->render(json => {error => $error}, status => 404);
    }

    $self->render(
        json => {
            $table => [
                map {
                    my $row      = $_;
                    my @settings = sort { $a->key cmp $b->key } $row->settings;
                    my %hash     = (
                        (
                            map {
                                my $val = $row->get_column($_);
                                $val ? ($_ => $val) : ()
                            } @{$tables{$table}->{cols}}
                        ),
                        settings => [map { {key => $_->key, value => $_->value} } @settings]);
                    \%hash;
                } @result
            ]});
}

sub create {
    my ($self)     = @_;
    my $table      = $self->param("table");
    my %entry      = %{$tables{$table}->{defaults}};
    my $validation = $self->validation;

    for my $par (@{$tables{$table}->{required}}) {
        $validation->required($par);
        $entry{$par} = $self->param($par);
    }
    $entry{description} = $self->param('description');
    my $hp = $self->hparams();
    my @settings;
    if ($hp->{settings}) {
        for my $k (keys %{$hp->{settings}}) {
            push @settings, {key => $k, value => $hp->{settings}->{$k}};
        }
    }
    $entry{settings} = \@settings;

    my $error;
    my $id;
    if ($validation->has_error) {
        $error = "wrong parameter: ";
        for my $par (@{$tables{$table}->{required}}) {
            $error .= " $par" if $validation->has_error($par);
        }
    }
    else {
        try { $id = $self->db->resultset($table)->create(\%entry)->id; } catch { $error = shift; };
    }
    if ($error) {
        return $self->render(json => {error => $error}, status => 400);
    }
    $self->emit_event('openqa_table_create', {table => $table, %entry});
    $self->render(json => {id => $id});
}

sub update {
    my ($self) = @_;
    my $table = $self->param("table");
    my %entry;
    my $validation = $self->validation;

    for my $par (@{$tables{$table}->{required}}) {
        $validation->required($par);
        $entry{$par} = $self->param($par);
    }
    $entry{description} = $self->param('description');
    my $hp = $self->hparams();
    my @settings;
    my @keys;
    if ($hp->{settings}) {
        for my $k (keys %{$hp->{settings}}) {
            push @settings, {key => $k, value => $hp->{settings}->{$k}};
            push @keys, $k;
        }
    }

    my $error;
    my $ret;
    if ($validation->has_error) {
        $error = "wrong parameter: ";
        for my $par (@{$tables{$table}->{required}}) {
            $error .= " $par" if $validation->has_error($par);
        }
    }
    else {
        my $update = sub {
            my $rc = $self->db->resultset($table)->find({id => $self->param('id')});
            if ($rc) {
                $rc->update(\%entry);
                for my $var (@settings) {
                    $rc->update_or_create_related('settings', $var);
                }
                $rc->delete_related('settings', {key => {'not in' => [@keys]}});
                $ret = 1;
            }
            else {
                $ret = 0;
            }
        };

        try {
            $self->db->txn_do($update);
        }
        catch {
            $error = shift;
            OpenQA::Utils::log_debug("Table update error: $error");
        };
    }

    if ($ret && $ret == 0) {
        return $self->render(json => {error => 'Not found'}, status => 404);
    }
    if (!$ret) {
        return $self->render(json => {error => $error}, status => 400);
    }
    $self->emit_event('openqa_table_update', {table => $table, name => $entry{name}, settings => \@settings});
    $self->render(json => {result => int($ret)});
}


sub destroy {
    my ($self)   = @_;
    my $table    = $self->param("table");
    my $machines = $self->db->resultset('Machines');
    my $ret;
    my $error;
    my $res;
    my $entry_name;

    try {
        my $rs = $self->db->resultset($table);
        $res = $rs->search({id => $self->param('id')});
        if ($res && $res->single) {
            $entry_name = $res->single->name;
        }
        $ret = $res->delete;
    }
    catch {
        $error = shift;
    };

    if ($ret && $ret == 0) {
        return $self->render(json => {error => 'Not found'}, status => 404);
    }
    if (!$ret) {
        return $self->render(json => {error => $error}, status => 400);
    }
    $self->emit_event('openqa_table_delete', {table => $table, name => $entry_name});
    $self->render(json => {result => int($ret)});
}

1;
