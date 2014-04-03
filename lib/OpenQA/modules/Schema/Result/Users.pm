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

package Schema::Result::Users;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('users');
__PACKAGE__->load_components(qw/InflateColumn::DateTime/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    openid => {
        data_type => 'text',
    },
    is_operator => {
        data_type => 'integer',
        is_boolean => 1,
        false_id => ['0', '-1'],
        default_value => '0',
    },
    is_admin => {
        data_type => 'integer',
        is_boolean => 1,
        false_id => ['0', '-1'],
        default_value => '0',
    },
    t_created => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_updated => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint(constraint_name => [qw/openid/]);
__PACKAGE__->has_many(api_keys => 'Schema::Result::ApiKeys', 'user_id');

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    db_helpers::create_auto_timestamps($sqlt_table->schema, __PACKAGE__->table);
}

sub name{
    my $self = shift;

    if (!$self->{_name}) {
        my $id = $self->openid;
        my ($path, $user) = split(/\/([^\/]+)$/, $id);
        $self->{_name} = $user;
    }
    return $self->{_name};
}

sub create_user{
    my $self = shift;
    my $id = shift;
    my $db = shift;

    my $user = $db->resultset("Users")->find_or_create({openid => $id});
    if(not $db->resultset("Users")->search({ is_admin => 1 })->single()) {
        $user->is_admin(1);
        $user->is_operator(1);
        $user->update;
    }
    return $user;
}

1;
# vim: set sw=4 et:
