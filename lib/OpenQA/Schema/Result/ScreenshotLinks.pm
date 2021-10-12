# Copyright 2016 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::ScreenshotLinks;

use strict;
use warnings;

use base 'DBIx::Class::Core';

__PACKAGE__->table('screenshot_links');

__PACKAGE__->add_columns(
    screenshot_id => {
        data_type => 'integer',
        is_nullable => 0,
    },
    job_id => {
        data_type => 'integer',
        is_nullable => 0,
    });

__PACKAGE__->belongs_to(job => 'OpenQA::Schema::Result::Jobs', 'job_id');
__PACKAGE__->belongs_to(screenshot => 'OpenQA::Schema::Result::Screenshots', 'screenshot_id');

1;
