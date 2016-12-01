# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::WebAPI::Controller::Admin::Table;
use Mojo::Base 'Mojolicious::Controller';

sub admintable {
    my ($self, $resultset, $template) = @_;

    my $rc = $self->db->resultset($resultset)->search(
        undef,
        {
            select   => ['key', {count => 'key'}],
            as       => [qw( key var_count )],
            group_by => [qw( key )],
            order_by => {-desc => 'count(key)'}});
    my @variables = map { $_->key } $rc->all();
    $self->stash('variables', \@variables);
    $self->render("admin/$template/index");
}

1;
