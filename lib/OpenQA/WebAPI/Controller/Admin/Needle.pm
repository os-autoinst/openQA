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

    time2str('%Y-%m-%d %H:%M:%S', time - $days * 3600 * 24, 'UTC');
}

sub _translate_cond($) {
    my ($cond) = @_;

    if ($cond =~ m/^min(\d+)$/) {
        return {">=" => _translate_days($1)};
    }
    elsif ($cond =~ m/^max(\d+)$/) {
        return {"<" => _translate_days($1)};
    }
    die "Unknown '$cond'";
}

sub ajax {
    my ($self) = @_;

    my @conds;

    # This < max and >= min is a bit awkward, but postgresql goes on strike if put too big IN $subquery on it
    # so this will be good enough
    my $seen_query = $self->param('last_seen');
    if ($seen_query && $seen_query ne 'none') {
        my $query = $self->db->resultset("JobModules")->search({t_created => _translate_cond($self->param('last_seen'))})->get_column('id');
        if ($seen_query =~ m/^max/) {
            push(@conds, {last_seen_module_id => {'<', $query->max}});
        }
        else {
            push(@conds, {last_seen_module_id => {'>=', $query->min}});
        }
    }
    my $match_query = $self->param('last_match');
    if ($match_query && $match_query ne 'none') {
        my $query = $self->db->resultset("JobModules")->search({t_created => _translate_cond($self->param('last_match'))})->get_column('id');
        if ($match_query =~ m/^max/) {
            push(@conds, {-or => [{last_matched_module_id => {'<', $query->max}}, {last_matched_module_id => undef}]});
        }
        else {
            push(@conds, {last_matched_module_id => {'>=', $query->min}});
        }
    }
    push(@conds, {file_present => 1});
    my $needles = $self->db->resultset("Needles")->search({-and => \@conds}, {prefetch => qw/directory/, order_by => 'filename'});

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
    my $jobmodules = $self->db->resultset("JobModules")->search({id => {-in => [keys %modules]}});
    # translate module id into time
    while (my $m = $jobmodules->next) {
        $modules{$m->id} = $m->t_created->datetime() . "Z";
    }
    for my $d (@data) {
        $d->{last_seen} = $modules{$d->{last_seen}};
        $d->{last_match} = $modules{$d->{last_match} || 0} || 'never';
    }
    $self->render(json => {data => \@data});
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

    for my $p (@{$self->every_param('id[]')}) {
        if (!$self->app->db->resultset('Needles')->find($p)->remove($self->current_user)) {
            $self->stash(error => "Error removing $p");
            last;
        }
    }
    $self->render(text => 'ok');
}

1;
# vim: set sw=4 et:
