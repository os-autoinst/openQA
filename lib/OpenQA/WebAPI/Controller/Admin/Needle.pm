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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Controller::Admin::Needle;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use Date::Format qw/time2str/;

sub index {
    my ($self) = @_;

    $self->render('admin/needle/index');
}

sub _translate_days($) {
    my ($days) = @_;
    return time2str('%Y-%m-%d %H:%M:%S', time - $days * 3600 * 24, 'UTC');
}

sub _translate_cond($) {
    my ($cond) = @_;

    if ($cond =~ m/^min(\d+)$/) {
        return {'>=' => _translate_days($1)};
    }
    elsif ($cond =~ m/^max(\d+)$/) {
        return {'<' => _translate_days($1)};
    }
    die "Unknown '$cond'";
}

sub ajax {
    my ($self) = @_;

    # Only consider needles where the file is present
    my @conds = ({file_present => 1});
    my $total_needle_count = $self->db->resultset('Needles')->search({-and => \@conds})->count;

    # Conditions for search
    my $search_value = $self->param('search[value]');
    push(@conds, {filename => {-like => '%' . $search_value . '%'}}) if $search_value;

    # Make columns directory.name, last_seen.t_created and last_match.t_created available by joining with JobModules
    # Required for ordering by those columns and also eases filtering
    my $params = {prefetch => [qw/directory/]};
    $params->{join} = [qw/directory last_seen last_match/];

    # Parameter for order
    my @columns = qw(directory.name filename last_seen.t_created last_match.t_created);
    my @order_by_params;
    my $index = 0;
    while (1) {
        my $column_index = $self->param("order[$index][column]");
        my $column_order = $self->param("order[$index][dir]");
        if (
            !(
                   defined($column_index)
                && $column_index < scalar(@columns)
                && ($column_order eq 'asc' || $column_order eq 'desc')))
        {
            last;
        }
        push(@order_by_params, {'-' . $column_order => $columns[$column_index]});
        ++$index;
    }
    push(@order_by_params, {-asc => 'filename'}) unless @order_by_params;
    $params->{order_by} = \@order_by_params;

    # Conditions for filter
    my $seen_query = $self->param('last_seen');
    if ($seen_query && $seen_query ne 'none') {
        push(@conds, {'last_seen.t_created' => _translate_cond($self->param('last_seen'))});
    }
    my $match_query = $self->param('last_match');
    if ($match_query && $match_query ne 'none') {
        push(@conds, {'last_match.t_created' => _translate_cond($self->param('last_match'))});
    }

    # Determine number of needles with all filters applied except paging
    my $filtered_needle_count = $self->db->resultset('Needles')->search({-and => \@conds}, $params)->count;

    # Parameter for paging
    my $first_row = $self->param('start');
    $params->{offset} = $first_row if $first_row;
    my $row_limit = $self->param('length');
    $params->{rows} = $row_limit if $row_limit;

    my $needles = $self->db->resultset('Needles')->search({-and => \@conds}, $params);

    my @data;
    my %modules;
    while (my $n = $needles->next) {
        my $hash = {
            id             => $n->id,
            directory      => $n->directory->name,
            filename       => $n->filename,
            last_seen      => $n->last_seen_module_id,
            last_seen_link => $self->url_for(
                'admin_needle_module',
                module_id => $n->last_seen_module_id,
                needle_id => $n->id
            )};
        $modules{$n->last_seen_module_id} = undef;
        if ($n->last_matched_module_id) {
            $hash->{last_match}      = $n->last_matched_module_id;
            $hash->{last_match_link} = $self->url_for(
                'admin_needle_module',
                module_id => $n->last_matched_module_id,
                needle_id => $n->id
            );
            $modules{$n->last_matched_module_id} = undef;
        }
        push(@data, $hash);
    }
    my $jobmodules = $self->db->resultset('JobModules')->search({id => {-in => [keys %modules]}});
    # translate module id into time
    while (my $m = $jobmodules->next) {
        $modules{$m->id} = $m->t_created->datetime() . 'Z';
    }
    for my $d (@data) {
        $d->{last_seen} = $modules{$d->{last_seen}};
        $d->{last_match} = $modules{$d->{last_match} || 0} || 'never';
    }

    $self->render(
        json => {
            recordsTotal    => $total_needle_count,
            recordsFiltered => $filtered_needle_count,
            data            => \@data
        });
}

sub module {
    my ($self) = @_;

    my $module = $self->db->resultset('JobModules')->find($self->param('module_id'));
    my $needle = $self->db->resultset('Needles')->find($self->param('needle_id'))->name;

    my $index = 1;
    for my $detail (@{$module->details}) {
        last if $detail->{needle} eq $needle;
        last if grep { $needle eq $_->{name} } @{$detail->{needles} || []};
        $index++;
    }
    $self->redirect_to('step', testid => $module->job_id, moduleid => $module->name(), stepid => $index);
}

sub delete {
    my ($self) = @_;
    my @removed_ids;
    my @errors;
    for my $needle_id (@{$self->every_param('id')}) {
        my $needle = $self->db->resultset('Needles')->find($needle_id);
        if (!$needle) {
            push(
                @errors,
                {
                    id           => $needle_id,
                    display_name => $needle_id,
                    message      => "Unable to find $needle_id"
                });
            next;
        }

        my $error = $needle->remove($self->current_user);
        if ($error) {
            push(
                @errors,
                {
                    id           => $needle_id,
                    display_name => $needle->filename,
                    message      => $error
                });
        }
        else {
            push(@removed_ids, $needle_id);
        }
    }
    $self->emit_event('openqa_needle_delete', {id => \@removed_ids});
    $self->render(
        json => {
            removed_ids => \@removed_ids,
            errors      => \@errors
        });
}

1;
# vim: set sw=4 et:
