# Copyright (C) 2017 SUSE Linux LLC
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

package OpenQA::WebAPI::Controller::API::V1::Bug;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::IPC;
use OpenQA::Utils;
use OpenQA::Schema::Result::Jobs;
use DBIx::Class::Timestamps 'now';
use Date::Format 'time2str';
use Try::Tiny;

sub list {
    my ($self) = @_;


    my $bugs;
    if ($self->param('refreshable')) {
        my $delta = $self->param('delta') || 3600;
        $bugs = $self->db->resultset("Bugs")->search(
            {
                -or => {
                    refreshed => 0,
                    t_updated => {'<=' => time2str('%Y-%m-%d %H:%M:%S', time - $delta, 'UTC')}
                },
                existing => 1
            });
    }
    else {
        $bugs = $self->db->resultset("Bugs");
    }

    my %ret = map { $_->id => $_->bugid } $bugs->all;
    $self->render(json => {bugs => \%ret});
}


sub show {
    my ($self) = @_;

    my $bug = $self->db->resultset("Bugs")->find($self->param('id'));

    unless ($bug) {
        $self->reply->not_found;
        return;
    }

    my %json = map { $_ => $bug->get_column($_) }
      qw(id bugid title priority assigned assignee open status resolution existing refreshed t_updated);
    $self->render(json => \%json);
}

sub create {
    my ($self) = @_;

    my $bug = $self->db->resultset("Bugs")->find({bugid => $self->param('bugid')});

    if ($bug) {
        $self->render(json => {error => 1});
        return;
    }

    $bug = $self->db->resultset("Bugs")->create({bugid => $self->param('bugid'), %{$self->get_bug_values}});
    $self->emit_event('openqa_bug_create', {id => $bug->id, bugid => $bug->bugid, fromapi => 1});
    $self->render(json => {id => $bug->id});
}

sub update {
    my ($self) = @_;

    my $bug = $self->db->resultset("Bugs")->find($self->param('id'));

    unless ($bug) {
        $self->reply->not_found;
        return;
    }

    $bug->update($self->get_bug_values);
    $self->emit_event('openqa_bug_update', {id => $bug->id, bugid => $bug->bugid});
    $self->render(json => {id => $bug->id});
}

sub destroy {
    my ($self) = @_;

    my $bug = $self->db->resultset("Bugs")->find($self->param('id'));

    unless ($bug) {
        $self->reply->not_found;
        return;
    }

    $self->emit_event('openqa_bug_delete', {id => $bug->id, bugid => $bug->bugid});
    $bug->delete;
    $self->render(json => {result => 1});
}

sub get_bug_values {
    my ($self) = @_;

    return {
        title      => $self->param('title'),
        priority   => $self->param('priority'),
        assigned   => $self->param('assigned') ? 1 : 0,
        assignee   => $self->param('assignee'),
        open       => $self->param('open') ? 1 : 0,
        status     => $self->param('status'),
        resolution => $self->param('resolution'),
        existing   => $self->param('existing') ? 1 : 0,
        t_updated  => time2str('%Y-%m-%d %H:%M:%S', time, 'UTC'),
        refreshed  => 1
    };
}

1;
# vim: set sw=4 et:
