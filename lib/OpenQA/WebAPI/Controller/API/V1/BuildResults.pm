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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Controller::API::V1::BuildResults;
use strict;
use warnings;
use OpenQA::BuildResults;
use Mojo::Base 'Mojolicious::Controller';

sub list {
    my ($self) = @_;

    my $limit_builds    = $self->param('limit_builds')    // 10;
    my $time_limit_days = $self->param('time_limit_days') // 14;

    my @results;
    my $groups = $self->db->resultset('JobGroups')->search({}, {order_by => qw/name/});
    while (my $group = $groups->next) {
        my $build_results = OpenQA::BuildResults::compute_build_results($self->app, $group, $limit_builds, $time_limit_days);
        if ($build_results) {
            my $group = delete $build_results->{_group};
            $build_results->{group_id}   = $group->id;
            $build_results->{group_name} = $group->name;
            $build_results->{max}        = delete $build_results->{_max};
            push(@results, $build_results);
        }
    }
    $self->render(json => \@results);
}

1;
# vim: set sw=4 et:
