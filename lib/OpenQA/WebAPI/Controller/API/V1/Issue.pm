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

package OpenQA::WebAPI::Controller::API::V1::Issue;
use Mojo::Base 'Mojolicious::Controller';

# use DBIx::Class::ResultClass::HashRefInflator;
use OpenQA::Utils;

use constant JOB_QUERY_LIMIT => 10000;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Issue

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Issue;

=head1 DESCRIPTION

OpenQA API implementation for assets handling methods.

=head1 METHODS

=back

=cut

sub jobs {
    my $self   = shift;
    my $schema = $self->schema;

    my $validation = $self->validation;
    $validation->optional('limit')->num(0);

    my $limit = $validation->param('limit') // JOB_QUERY_LIMIT;
    return $self->render(json => {error => 'Limit exceeds maximum'}, status => 400) unless $limit <= JOB_QUERY_LIMIT;

    my $rs = $schema->resultset("JobSettings")->search({
        key => {like => '%ISSUE%'},
        value => {like => '%'.$self->stash("id").'%'}
    }, {
        rows => $limit,
        distinct => 1,
        group_by => [qw{ job_id }],
        select => [ 'job_id' ]
    });

    $self->render(json => {jobs => [map { $_->job_id } $rs->all]});
}

1;
