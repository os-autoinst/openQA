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

package OpenQA::Controller::ApiKey;
use Mojo::Base 'Mojolicious::Controller';
use DateTime::Format::SQLite;

sub index {
    my $self = shift;
    my @keys = $self->current_user->api_keys;

    $self->stash('keys', \@keys);
}

sub create {
    my $self = shift;
    my $user = $self->current_user;
    my $expiration;
    my $validation = $self->validation;
    my $re = qr/^\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2}(?::\d{2})?)?$/a;
    $validation->optional('t_expiration')->like($re);
    my $error;
    if ($validation->has_error) {
        $error = "Date must be in format $re";
    }
    if (!$error && $validation->is_valid('t_expiration')) {
        eval { $expiration = DateTime::Format::SQLite->parse_datetime($self->param('t_expiration')) };
        $error = $@;
    }
    unless ($error) {
        eval { $self->db->resultset("ApiKeys")->create({user_id => $user->id, t_expiration => $expiration}) };
        $error = $@;
    }
    if ($error) {
        my $msg = "Error adding the API key: $error";
        $self->app->log->debug($msg);
        $self->flash(error => $msg);
    }
    $self->redirect_to(action => 'index');
}

sub destroy {
    my $self = shift;
    my $user = $self->current_user;
    my $key = $user->find_related('api_keys', {id => $self->param('apikeyid')});

    if ($key) {
        $key->delete;
        $self->flash(info => 'API key deleted');
    }
    else {
        $self->flash(error => 'API key not found');
    }
    $self->redirect_to($self->url_for('api_keys'));
}

1;
# vim: set sw=4 et:
