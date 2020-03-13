# Copyright (C) 2015-2019 SUSE LLC
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
use Mojo::Base 'Mojolicious::Controller';

use 5.018;

use Time::Piece;
use Time::Seconds;
use Time::ParseDate;
use Mojo::JSON 'encode_json';
use OpenQA::ServerSideDataTable;

sub index {
    my ($self) = @_;
    $self->stash(audit_enabled => $self->app->config->{global}{audit_enabled});
    if ($self->param('eventid')) {
        $self->stash('search', 'id:' . $self->param('eventid'));
        return $self->render('admin/audit_log/index');
    }
    $self->stash('search', $self->param('search'));
    $self->render('admin/audit_log/index');
}

sub productlog {
    my ($self)             = @_;
    my $entries            = $self->param('entries') // 100;
    my $scheduled_products = $self->schema->resultset('ScheduledProducts')
      ->search(undef, {order_by => {-desc => 'me.id'}, prefetch => 'triggered_by', rows => $entries});
    my @scheduled_products;
    while (my $scheduled_product = $scheduled_products->next) {
        my $responsible_user = $scheduled_product->triggered_by;
        my $data             = $scheduled_product->to_hash;
        $data->{user_name}       = $responsible_user ? $responsible_user->name : 'system';
        $data->{settings_string} = encode_json($data->{settings});
        $data->{results_string}  = encode_json($data->{results});
        push(@scheduled_products, $data);
    }
    $self->stash(isos         => \@scheduled_products);
    $self->stash(show_actions => $self->is_operator);
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
    elsif ($key eq 'id') {
        push(@{$query->{$key}}, ("CAST(me.id AS text)" => {-like => '%' . $search . '%'}));
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
