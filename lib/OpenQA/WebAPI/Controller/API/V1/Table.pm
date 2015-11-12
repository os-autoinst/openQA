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
    'Machines' => {
        'keys' => [['id'], ['name'],],
        'cols'     => ['id',   'name', 'backend'],
        'required' => ['name', 'backend'],
        'defaults' => {'variables' => ""},
    },
    'TestSuites' => {
        'keys' => [['id'], ['name'],],
        'cols'     => ['id', 'name'],
        'required' => ['name'],
        'defaults' => {'variables' => ""},
    },
    'Products' => {
        'keys' => [['id'], ['distri', 'version', 'arch', 'flavor'],],
        'cols'     => ['id',     'distri',  'version', 'arch', 'flavor'],
        'required' => ['distri', 'version', 'arch',    'flavor'],
        'defaults' => {'variables' => "", 'name' => ""},
    },
);


sub list {
    my $self = shift;

    my $table = $self->param("table");
    my %search;

    for my $key (@{$tables{$table}->{'keys'}}) {
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
        if (%search) {
            @result = $self->db->resultset($table)->search(\%search);
        }
        else {
            @result = $self->db->resultset($table)->all;
        }
    };
    my $error = $@;

    if ($error) {
        $self->render(json => {error => $error}, status => 404);
        return;
    }

    $self->render(
        json => {
            $table => [
                map {
                    my $row = $_;
                    my %hash = ((map { ($_ => $row->get_column($_)) } @{$tables{$table}->{'cols'}}), settings => [map { {key => $_->key, value => $_->value} } $row->settings]);
                    \%hash;
                } @result
            ]});
}

sub create {
    my $self  = shift;
    my $table = $self->param("table");

    my $error;
    my $id;

    my %entry      = %{$tables{$table}->{'defaults'}};
    my $validation = $self->validation;

    for my $par (@{$tables{$table}->{'required'}}) {
        $validation->required($par);
        $entry{$par} = $self->param($par);
    }
    my $hp = $self->hparams();
    my @settings;
    if ($hp->{'settings'}) {
        for my $k (keys %{$hp->{'settings'}}) {
            push @settings, {'key' => $k, 'value' => $hp->{'settings'}->{$k}};
        }
    }
    $entry{'settings'} = \@settings;

    if ($validation->has_error) {
        $error = "wrong parameter: ";
        for my $par (@{$tables{$table}->{'required'}}) {
            $error .= " $par" if $validation->has_error($par);
        }
    }
    else {
        try { $id = $self->db->resultset($table)->create(\%entry)->id; } catch { $error = shift; };
    }

    my $status;
    my $json = {};

    if ($error) {
        $self->emit_event('table_create_req', {table => $table, result => 'failure', %entry});
        $json->{error} = $error;
        $status = 400;
    }
    else {
        $self->emit_event('table_create_req', {table => $table, result => 'success', %entry});
        $json->{id} = $id;
    }

    $self->render(json => $json, status => $status);
}

sub update {
    my $self  = shift;
    my $table = $self->param("table");

    my $error;
    my $ret;
    my %entry;
    my $validation = $self->validation;

    for my $par (@{$tables{$table}->{'required'}}) {
        $validation->required($par);
        $entry{$par} = $self->param($par);
    }

    my $hp = $self->hparams();
    my @settings;
    my @keys;
    if ($hp->{'settings'}) {
        for my $k (keys %{$hp->{'settings'}}) {
            push @settings, {'key' => $k, 'value' => $hp->{'settings'}->{$k}};
            push @keys, $k;
        }
    }

    $entry{'variables'} = '';

    if ($validation->has_error) {
        $error = "wrong parameter: ";
        for my $par (@{$tables{$table}->{'required'}}) {
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
                $rc->delete_related('settings', {'key' => {'not in' => [@keys]}});
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

    my $status;
    my $json = {};

    if ($ret) {
        if ($ret == 0) {
            $status = 404;
            $error  = 'Not found';
            $self->emit_event('table_update_req', {table => $table, result => 'failure', name => $entry{name}, settings => \@settings});
        }
        else {
            $json->{result} = int($ret);
            $self->emit_event('table_update_req', {table => $table, result => 'success', name => $entry{name}, settings => \@settings});
        }
    }
    else {
        # no need for emiting here, this is called in case of wrong parameters -> not emitting req part
        $json->{error} = $error;
        $status = 400;
    }

    $self->render(json => $json, status => $status);
}


sub destroy {
    my $self  = shift;
    my $table = $self->param("table");

    my $machines = $self->db->resultset('Machines');

    my $status;
    my $json = {};

    my $ret;
    my $error;

    my $res;

    try {
        my $rs = $self->db->resultset($table);
        $res = $rs->search({id => $self->param('id')});
        $ret = $res->delete;
    }
    catch {
        $error = shift;
    };

    if ($ret) {
        if ($ret == 0) {
            $status = 404;
            $error  = 'Not found';
            $self->emit_event('table_delete_req', {table => $table, result => 'failure', id => $self->param('id')});
        }
        else {
            $json->{result} = int($ret);
            $self->emit_event('table_delete_req', {table => $table, name => $res->single->name});
        }
    }
    else {
        $json->{error} = $error;
        $status = 400;
        $self->emit_event('table_delete_req', {result => 'failure'});
    }

    $self->render(json => $json, status => $status);
}

1;
