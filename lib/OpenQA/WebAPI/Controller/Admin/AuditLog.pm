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

sub _addSingleQuery {
    my ($query, $key, $search) = @_;
    if (grep { $key eq $_ } qw(event owner.nickname connection_id id event_data)) {
        push @{$query->{$key}}, ($key => {-like => '%' . $search . '%'});
    }
    elsif ($key eq 'me.t_created') {
        my $t = parsedate($search, PREFER_PAST => 1, DATE_REQUIRED => 1);
        my $t_end;
        if ($search =~ /week/) {
            $t_end = ONE_WEEK;
        }
        elsif ($search =~ /month/) {
            $t_end = ONE_MONTH;
        }
        elsif ($search =~ /year/) {
            $t_end = ONE_YEAR;
        }
        else {
            $t_end = ONE_DAY;
        }

        if ($t) {
            $t = localtime($t);
            push @{$query->{$key}}, (-and => [$key => {'>=' => $t->ymd()}, $key => {'<' => ($t + $t_end)->ymd()}]);
        }
    }
}

sub _getSearchQuery {
    my ($search) = @_;

    my $query = {};
    # rename some frequent queries to respective column names
    $search =~ s/owner:/owner.nickname:/g;
    $search =~ s/user:/owner.nickname:/g;
    $search =~ s/date:/me.t_created:/g;
    $search =~ s/data:/event_data:/g;
    $search =~ s/connection:/connection_id:/g;

    # construct query only from allowed columns
    my @subsearch      = split(/ /, $search);
    my $current_key    = 'event_data';
    my $current_search = '';
    for my $s (@subsearch) {
        if (CORE::index($s, ':') == -1) {
            # bareword - add to current_search
            $current_search .= ' ' . $s;
        }
        else {
            # we are starting new search group, push the current to the query
            _addSingleQuery($query, $current_key, $current_search) if $current_search;

            my ($key, $search) = split(/:/, $s);
            # new search column found, assign key as current key and reset search to new search
            $current_key    = $key;
            $current_search = $search;
        }
    }
    # add the last single query if anything is entered
    _addSingleQuery($query, $current_key, $current_search) if $current_search;

    # add proper -and => -or structure to constructed query
    my $res;
    for my $k (keys %$query) {
        push @{$res->{-and}}, (-or => $query->{$k});
    }
    return $res;
}

sub _getOrdering {
    my ($order_col, $order) = @_;
    my %column_translation = (
        event_time => 'me.t_created',
        connection => 'connection_id',
        user       => 'owner.nickname',
        event_data => 'event_data',
        event      => 'event'
    );

    return {"-$order" => $column_translation{$order_col}};
}

sub ajax {
    my ($self) = @_;

    my $startRow = $self->param('start')         // 1;
    my $rows     = $self->param('length')        // 20;
    my $page     = int($startRow / $rows) + 1;
    my $search   = $self->param('search[value]') // '';
    my $echo = int($self->param('_') // 0);
    my $order_by = $self->param('order[0][column]') // 0;
    my $order_cl = $self->param("columns[$order_by][data]");
    my $order    = $self->param('order[0][dir]') // 'desc';

    my $query = _getSearchQuery($search);
    $order = _getOrdering($order_cl, $order);

    my $events_rs = $self->db->resultset('AuditEvents')->search(undef, {prefetch => 'owner', cache => 1});
    my $fullSize = $events_rs->count;
    $events_rs = $events_rs->search($query);
    my $filteredSize = $events_rs->count;
    $events_rs = $events_rs->search(undef, {order_by => $order, rows => $rows, page => $page});
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
    $self->render(
        json => {sEcho => $echo, aaData => \@events, iTotalRecords => $fullSize, iTotalDisplayRecords => $filteredSize}
    );
}

1;
