# Copyright (C) 2016 SUSE Linux GmbH
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

package OpenQA::WebAPI::Controller::API::V1::Audit;
use Mojo::Base 'Mojolicious::Controller';
use JSON ();
use Try::Tiny;

sub replayEvent {
    my ($self) = @_;

    my $eventId = $self->param('eventId');
    my $event   = $self->app->schema->resultset('AuditEvents')->find($eventId);
    if (!$event) {
        return $self->rendered(404);
    }

    my $event_type = $event->event;
    my $json       = JSON->new();
    $json->allow_nonref(1);
    if ($event_type eq 'iso_create') {
        my $settings;
        try {
            $settings = $json->decode($event->event_data);
        }
        catch {
            return $self->rendered(500);
        };

        delete $settings->{id};
        require OpenQA::WebAPI::Controller::API::V1::Iso;
        my ($cnt, $ids) = $self->OpenQA::WebAPI::Controller::API::V1::Iso::schedule_iso($settings);
        return $self->render(json => {count => $cnt, ids => $ids});
    }
    else {
        return $self->rendered(400);
    }
}

1;
