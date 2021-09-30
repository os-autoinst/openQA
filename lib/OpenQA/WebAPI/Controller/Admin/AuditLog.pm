# Copyright 2015-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later


package OpenQA::WebAPI::Controller::Admin::AuditLog;
use Mojo::Base 'Mojolicious::Controller';

use 5.018;

use Time::Piece;
use Time::Seconds;
use Time::ParseDate;
use Mojo::JSON 'encode_json';
use OpenQA::WebAPI::ServerSideDataTable;

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
    my ($self) = @_;
    $self->render('admin/audit_log/productlog');
}

sub productlog_ajax {
    my ($self) = @_;

    my @searchable_columns = qw(me.distri me.version me.flavor me.arch me.build me.iso);
    my @filter_conds;
    if (my $id = $self->param('id')) {
        push(@filter_conds, {'me.id' => $id});
    }
    if (my $search_value = $self->param('search[value]')) {
        my %condition = (like => "\%$search_value%");
        push(@filter_conds, {-or => [map { $_ => \%condition } @searchable_columns]});
    }

    OpenQA::WebAPI::ServerSideDataTable::render_response(
        controller => $self,
        resultset => 'ScheduledProducts',
        columns => [qw(me.id me.t_created me.status me.settings me.results), @searchable_columns],
        filter_conds => (@filter_conds ? \@filter_conds : undef),
        additional_params => {prefetch => 'triggered_by', cache => 1},
        prepare_data_function => sub {
            my ($scheduled_products) = @_;
            my @scheduled_products;
            while (my $scheduled_product = $scheduled_products->next) {
                my $data = $scheduled_product->to_hash;
                my $responsible_user = $scheduled_product->triggered_by;
                $data->{user_name} = $responsible_user ? $responsible_user->name : 'system';
                push(@scheduled_products, $data);
            }
            return \@scheduled_products;
        },
    );
}

sub _add_single_query {
    my ($query, $key, $search_terms) = @_;

    return unless @$search_terms;
    my $search = join(' ', @$search_terms);
    @$search_terms = ();

    my %key_mapping = (
        owner => 'owner.nickname',
        user => 'owner.nickname',
        data => 'event_data',
        connection => 'connection_id',
        event => 'event',
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
    my $query = {};
    my @subsearch = split(/ /, $raw_search);
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

    OpenQA::WebAPI::ServerSideDataTable::render_response(
        controller => $self,
        resultset => 'AuditEvents',
        columns => [qw(me.t_created connection_id owner.nickname event_data event)],
        filter_conds => _get_search_query($self->param('search[value]') // ''),
        additional_params => {
            prefetch => 'owner',
            cache => 1
        },
        prepare_data_function => sub {
            my ($results) = @_;
            my @events;
            while (my $event = $results->next) {
                push(
                    @events,
                    {
                        id => $event->id,
                        user => $event->owner ? $event->owner->nickname : 'system',
                        connection => $event->connection_id,
                        event => $event->event,
                        event_data => $event->event_data,
                        event_time => $event->t_created,
                    });
            }
            return \@events;
        },
    );
}

1;
