# Copyright (C) 2015 SUSE LLC
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


package OpenQA::WebAPI::Controller::Admin::AuditLog;
use strict;
use parent 'Mojolicious::Controller';

sub index {
    my ($self) = @_;
    $self->stash(audit_enabled => $self->app->config->{global}{audit_enabled});
    $self->render('admin/audit_log/index');
}

sub ajax {
    my ($self) = @_;
    my $events_rs = $self->app->db->resultset("AuditEvents")->search(undef, {order_by => 'me.id', prefetch => 'owner', rows => 300});
    my @events;
    while (my $event = $events_rs->next) {
        my $data = {
            id         => $event->id,
            user       => $event->owner ? $event->owner->nickname : 'system',
            connection => $event->connection_id,
            event      => $event->event,
            event_data => $event->event_data,
            event_time => $event->t_created,
        };
        push @events, $data;
    }
    $self->render(json => {data => \@events});
}

1;
