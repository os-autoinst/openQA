# Copyright 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::AuditEvents;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('audit_events');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 1
    },
    connection_id => {
        data_type => 'text',
        is_nullable => 1
    },
    event => {
        data_type => 'text',
        is_nullable => 0
    },
    event_data => {
        data_type => 'text',
        is_nullable => 1
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(owner => 'OpenQA::Schema::Result::Users', 'user_id', {join_type => 'left'});

1;
