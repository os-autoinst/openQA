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


package OpenQA::WebAPI::Controller::Admin::AuditLog;
use 5.018;
use warnings;
use parent 'Mojolicious::Controller';
use Time::Piece;
use Time::Seconds;
use Time::ParseDate;
use JSON ();
use OpenQA::Utils 'log_warning';
use OpenQA::ServerSideDataTable;

sub index {
    my ($self) = @_;
    $self->stash(audit_enabled => $self->app->config->{global}{audit_enabled});
    if ($self->param('eventid')) {
        my $event
          = $self->db->resultset('AuditEvents')->search({'me.id' => $self->param('eventid')}, {prefetch => 'owner'});
        if ($event) {
            $event = $event->single;
            $self->stash('id',         $event->id);
            $self->stash('date',       $event->t_created);
            $self->stash('event',      $event->event);
            $self->stash('connection', $event->connection_id);
            $self->stash('owner',      $event->owner->nickname);
            $self->stash('event_data', $event->event_data);
            return $self->render('admin/audit_log/event');
        }
    }
    $self->stash('search', $self->param('search'));
    $self->render('admin/audit_log/index');
}

sub productlog {
    my ($self) = @_;
    $self->stash(audit_enabled => $self->app->config->{global}{audit_enabled});
    my $events_rs = $self->db->resultset("AuditEvents")
      ->search({event => 'iso_create'}, {order_by => {-desc => 'me.id'}, prefetch => 'owner', rows => 100});
    my @events;
    my $json = JSON->new();
    $json->allow_nonref(1);
    while (my $event = $events_rs->next) {
        my $data = {
            id         => $event->id,
            user       => $event->owner ? $event->owner->nickname : 'system',
            event_data => $event->event_data,
            event_time => $event->t_created,
        };
        push @events, $data;
    }
    $self->stash(isos => \@events);
    $self->render('admin/audit_log/productlog');
}

sub _add_single_query {
    my ($query, $key, $search_terms) = @_;

    return unless @$search_terms;
    my $search = join(' ', @$search_terms);
    @$search_terms = ();

    my %key_mapping = (
        owner      => 'owner.nickname',
        user       => 'owner.nickname',
        data       => 'event_data',
        connection => 'connection_id',
        event      => 'event',
    );
    if (my $actual_key = $key_mapping{$key}) {
        push(@{$query->{$actual_key}}, ($actual_key => {-like => '%' . $search . '%'}));
    }
    elsif ($key eq 'older' || $key eq 'newer') {
        if ($search eq 'today') {
            $search = '1 day ago';
        }
        elsif ($search eq 'yesterday') {
            $search = '2 days ago';
        }
        else {
            $search = '1 ' . $search unless $search =~ /^[\s\d]/;
            $search .= ' ago' unless $search =~ /\sago\s*$/;
        }
        if (my $time = parsedate($search, PREFER_PAST => 1, DATE_REQUIRED => 1)) {
            my $time_conditions = ($query->{'me.t_created'} //= {-and => []});
            push(
                @{$time_conditions->{-and}},
                {
                    'me.t_created' => {
                        ($key eq 'newer' ? '>=' : '<') => localtime($time)->ymd()}});
        }
    }
}

sub _get_search_query {
    my ($raw_search) = @_;

    # construct query only from allowed columns
    my $query       = {};
    my @subsearch   = split(/ /, $raw_search);
    my $current_key = 'data';
    my @current_search;
    for my $s (@subsearch) {
        if (CORE::index($s, ':') == -1) {
            # bareword - add to current_search
            push(@current_search, $s);
        }
        else {
            # we are starting new search group, push the current to the query and reset it
            _add_single_query($query, $current_key, \@current_search);

            my ($key, $search_term) = split(/:/, $s);
            # new search column found, assign key as current key
            $current_key = $key;
            push(@current_search, $search_term);
        }
    }
    # add the last single query if anything is entered
    _add_single_query($query, $current_key, \@current_search);

    # add proper -and => -or structure to constructed query
    my @filter_conds;
    for my $k (keys %$query) {
        push(@filter_conds, (-or => $query->{$k}));
    }
    return \@filter_conds;
}

sub ajax {
    my ($self) = @_;

    OpenQA::ServerSideDataTable::render_response(
        controller        => $self,
        resultset         => 'AuditEvents',
        columns           => [qw(me.t_created connection_id owner.nickname event_data event)],
        filter_conds      => _get_search_query($self->param('search[value]') // ''),
        additional_params => {
            prefetch => 'owner',
            cache    => 1
        },
        prepare_data_function => sub {
            my ($results) = @_;
            my @events;
            while (my $event = $results->next) {
                push(
                    @events,
                    {
                        id         => $event->id,
                        user       => $event->owner ? $event->owner->nickname : 'system',
                        connection => $event->connection_id,
                        event      => $event->event,
                        event_data => $event->event_data,
                        event_time => $event->t_created,
                    });
            }
            return \@events;
        },
    );
}

1;
