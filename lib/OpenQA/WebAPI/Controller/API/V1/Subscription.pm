# Copyright (C) 2016 SUSE LLC
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

package OpenQA::WebAPI::Controller::API::V1::Subscription;
use Date::Format;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::IPC;

sub list {
    my ($self) = @_;

    # find group subscriptions
    my $res = $self->app->schema->resultset('JobGroupSubscriptions')->search(
        {
            user_id => $self->current_user->id
        });

    my @groups;
    while (my $sub = $res->next) {
        push(@groups, {group_id => $sub->group_id, flags => $sub->flags});
    }

    $self->render(
        json => {
            groups => \@groups
        });
}

sub subscribe {
    my ($self) = @_;

    my $group_id = $self->param('group_id');
    my $flags    = $self->param('flags');
    return $self->render(json => {error => 'No/invalid group specified'}, status => 400) unless $group_id;
    return $self->render(json => {error => 'No/invalid flags specified'}, status => 400) unless defined($flags);

    # find group subscriptions
    my $res = $self->app->schema->resultset('JobGroupSubscriptions')->update_or_create(
        {
            user_id  => $self->current_user->id,
            group_id => $group_id,
            flags    => $flags
        });
    return $self->render(json => {error => 'Unable to subscribe'}, status => 400) unless $res;
    $self->render(json => {status => 'ok'});
}

1;
# vim: set sw=4 et:
