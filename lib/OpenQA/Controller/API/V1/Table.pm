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

package OpenQA::Controller::API::V1::Table;
use Mojo::Base 'Mojolicious::Controller';

my %tables = (
    'Machines' => {
        'keys' => [['id'],['name'],],
        'cols' => [ 'id', 'name', 'backend' ],
        'required' => [ 'name', 'backend' ],
        'defaults' => { 'variables' => "" },
    },
    'TestSuites' => {
        'keys' => [['id'],['name'],],
        'cols' => [ 'id', 'name', 'prio' ],
        'required' => [ 'name', 'prio' ],
        'defaults' => { 'variables' => "" },
    },
    'Products' => {
        'keys' => [['id'],['distri', 'version', 'arch', 'flavor' ],],
        'cols' => [ 'id', 'distri', 'version', 'arch', 'flavor' ],
        'required' => [ 'distri', 'version', 'arch', 'flavor' ],
        'defaults' => { 'variables' => "", 'name' => "" },
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
                    my %hash = (( map { ( $_ => $row->get_column($_) ) } @{$tables{$table}->{'cols'}} ),settings => [ map { { key => $_->key, value => $_->value } } $row->settings ]);
                    \%hash;
                } @result
            ]
        }
    );
}

sub create {
    my $self = shift;
    my $table = $self->param("table");

    my $error;
    my $id;

    my %entry = %{$tables{$table}->{'defaults'}};
    my $validation = $self->validation;

    for my $par (@{$tables{$table}->{'required'}}) {
        $validation->required($par);
        $entry{$par} = $self->param($par);
    }
    my $hp = $self->hparams();
    my @settings;
    if ($hp->{'settings'}) {
        for my $k (keys %{$hp->{'settings'}}) {
            push @settings, {'key' => $k, 'value' => $hp->{'settings'}->{$k} };
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
        eval { $id = $self->db->resultset($table)->create(\%entry)->id};
        $error = $@;
    }

    my $status;
    my $json = {};

    if ($error) {
        $json->{error} = $error;
        $status = 400;
    }
    else {
        $json->{id} = $id;
    }

    $self->render(json => $json, status => $status);
}

sub update {
    my $self = shift;
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
            push @settings, {'key' => $k, 'value' => $hp->{'settings'}->{$k} };
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
        eval {
            my $rc = $self->db->resultset($table)->find({id => $self->param('id')});
            if ($rc) {
                $rc->update(\%entry);
                for my $var (@settings) {
                    $rc->update_or_create_related('settings', $var);
                }
                $rc->delete_related('settings', {'key' => { 'not in' => [@keys] }});
                $ret = 1;
            }
            else {
                $ret = 0;
            }
        };
        $error = $@;
    }

    my $status;
    my $json = {};

    if ($ret) {
        if ($ret == 0) {
            $status = 404;
            $error = 'Not found';
        }
        else {
            $json->{result} = int($ret);
        }
    }
    else {
        $json->{error} = $error;
        $status = 400;
    }

    $self->render(json => $json, status => $status);
}


sub destroy {
    my $self = shift;
    my $table = $self->param("table");

    my $machines = $self->db->resultset('Machines');

    my $status;
    my $json = {};

    my $ret;

    eval {
        my $rs = $self->db->resultset($table);
        $ret = $rs->search({id => $self->param('id')})->delete;
    };
    my $error = $@;

    if ($ret) {
        if ($ret == 0) {
            $status = 404;
            $error = 'Not found';
        }
        else {
            $json->{result} = int($ret);
        }
    }
    else {
        $json->{error} = $error;
        $status = 400;
    }

    $self->render(json => $json, status => $status);
}

1;
