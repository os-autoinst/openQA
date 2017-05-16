# Copyright (C) 2017 SUSE Linux GmbH
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

package OpenQA::Worker::Cache::Schema::Result::Assets;
use base 'DBIx::Class::Core';
use strict;

use JSON;
use db_helpers;

__PACKAGE__->table('cache_assets');
__PACKAGE__->load_components(qw(InflateColumn::DateTime FilterColumn Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    filename => {
        data_type   => 'text',
        is_nullable => 0,
    },
    etag => {
        data_type   => 'text',
        is_nullable => 0,
    },
    registered => {
        data_type   => 'datetime',
        is_nullable => 0,
    },
    last_used => {
        data_type   => 'datetime',
        is_nullable => 0,
    },
    size => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    downloading => {
        data_type   => 'text',
        is_nullable => 0,
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');

__PACKAGE__->add_unique_constraint([qw(filename)]);

# __PACKAGE__->filter_column(
#     args => {
#         filter_to_storage   => 'encode_json_to_db',
#         filter_from_storage => 'decode_json_from_db',
#     });

# sub sqlt_deploy_hook {
#     my ($self, $sqlt_table) = @_;

#     $sqlt_table->add_index(name => 'gru_tasks_run_at_reversed', fields => 'run_at DESC');
# }

# sub decode_json_from_db {
#     my $ret = JSON::decode_json($_[1]);
#     return $ret->{_} if ref($ret) eq 'HASH' && defined $ret->{_};
#     return $ret;
# }

# sub encode_json_to_db {
#     my $args = $_[1];
#     if (!ref($args)) {
#         $args = {'_' => $args};
#     }
#     JSON::encode_json($args);
# }

1;
# vim: set sw=4 et:
