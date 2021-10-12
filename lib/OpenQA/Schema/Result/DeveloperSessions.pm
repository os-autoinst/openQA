# Copyright 2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::DeveloperSessions;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Date::Format;
use Try::Tiny;

__PACKAGE__->table('developer_sessions');
__PACKAGE__->load_components(qw(Timestamps));
__PACKAGE__->add_columns(
    job_id => {
        data_type => 'integer',
        is_nullable => 0,
        is_foreign_key => 1,
    },
    user_id => {
        data_type => 'integer',
        is_nullable => 0,
        is_foreign_key => 1,
    },
    ws_connection_count => {
        data_type => 'integer',
        default_value => 0,
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('job_id');
__PACKAGE__->belongs_to(
    job => 'OpenQA::Schema::Result::Jobs',
    'job_id',
    {join_type => 'left'});
__PACKAGE__->belongs_to(
    user => 'OpenQA::Schema::Result::Users',
    'user_id',
    {join_type => 'left'});

1;
