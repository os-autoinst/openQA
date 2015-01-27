# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Admin::Machine;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my $self = shift;

    my $rc = $self->db->resultset("MachineSettings")->search(
        undef,
        {
            select   => [ 'key', { count => 'key' } ],
            as       => [qw/ key var_count /],
            group_by => [qw/ key /],
            order_by => { -desc => \'count(key)' }
        }
    );
    my @variables = map { $_->key } $rc->all();
    $self->stash('variables', \@variables);

    my @col_variables = @variables;
    splice @col_variables, 7;

    $self->stash('col_var_keys', \@col_variables);

    $self->render('admin/machine/index');
}

1;
