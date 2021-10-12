# Copyright 2016-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Screenshots;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('screenshots');
__PACKAGE__->load_components(qw(InflateColumn::DateTime));

__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    filename => {
        data_type => 'text',
        is_nullable => 0,
    },
    # we don't care for t_updated, so just add t_created
    t_created => {
        data_type => 'timestamp',
        is_nullable => 0,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(filename)]);
__PACKAGE__->has_many(
    links => 'OpenQA::Schema::Result::ScreenshotLinks',
    'screenshot_id',
    {cascade_delete => 0});
__PACKAGE__->has_many(
    links_outer => 'OpenQA::Schema::Result::ScreenshotLinks',
    'screenshot_id',
    {join_type => 'left outer', cascade_delete => 0});

1;
