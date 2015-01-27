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

package OpenQA::Schema::Result::ApiKeys;
use base qw/DBIx::Class::Core/;

use db_helpers;

__PACKAGE__->table('api_keys');
__PACKAGE__->load_components(qw/InflateColumn::DateTime Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    key => {
        data_type => 'text',
    },
    secret => {
        data_type => 'text',
    },
    user_id => {
        data_type => 'integer',
        is_foreign_key => 1,
    },
    t_expiration => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw/key/]);
__PACKAGE__->belongs_to(user => 'OpenQA::Schema::Result::Users', 'user_id');

sub new {
    my ( $class, $attrs ) = @_;

    $attrs->{key} = db_helpers::rndhexU unless $attrs->{key};
    $attrs->{secret} = db_helpers::rndhexU unless $attrs->{secret};

    my $new = $class->next::method($attrs);
    return $new;
}

1;
# vim: set sw=4 et:
