# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::SshKeys;
use Mojo::Base 'DBIx::Class::Core', -signatures;

__PACKAGE__->table('ssh_keys');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'bigint',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'bigint',
        is_foreign_key => 1,
    },
    public_key => {
        data_type => 'text',
    },
    fingerprint => {
        data_type => 'text',
    },
    title => {
        data_type => 'text',
    },
    last_used => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(fingerprint)]);
__PACKAGE__->belongs_to(user => 'OpenQA::Schema::Result::Users', 'user_id');

1;
