#!/usr/bin/env perl -w

# Copyright (C) 2019 SUSE Linux LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Schema::Result::ScreenshotLinks;
use Test::More;
use Test::Mojo;
use Test::Warnings;

my $schema           = OpenQA::Test::Database->new->create;
my $t                = Test::Mojo->new('OpenQA::WebAPI');
my $screenshots      = $schema->resultset('Screenshots');
my $screenshot_links = $schema->resultset('ScreenshotLinks');
my $jobs             = $schema->resultset('Jobs');

# add two screenshots to a job
OpenQA::Schema::Result::ScreenshotLinks::populate_images_to_job($schema, [qw(foo bar)], 99926);
my @screenshot_links = $screenshot_links->search({job_id => 99926})->all;
my @screenshot_ids   = map { $_->screenshot_id } @screenshot_links;
my @screenshots      = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
my @screenshot_data  = map { {filename => $_->filename, link_count => $_->link_count} } @screenshots;
is(scalar @screenshot_links, 2, '2 screenshot links for job 99926 created');
is_deeply(
    \@screenshot_data,
    [{filename => 'foo', link_count => 1}, {filename => 'bar', link_count => 1},],
    'link_count set'
) or diag explain \@screenshot_data;

# add one of the screenshots to another job expecting the screenshot's link_count to increase
OpenQA::Schema::Result::ScreenshotLinks::populate_images_to_job($schema, [qw(foo)], 99927);
@screenshot_links = $screenshot_links->search({job_id => 99927})->all;
@screenshots      = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data  = map { {filename => $_->filename, link_count => $_->link_count} } @screenshots;
is(scalar @screenshot_links, 1, 'screenshot link for job 99927 created');
is_deeply(
    \@screenshot_data,
    [{filename => 'foo', link_count => 2}, {filename => 'bar', link_count => 1},],
    'link_count for foo increased'
) or diag explain \@screenshot_data;

# delete the first job
$jobs->find(99926)->delete;
@screenshots     = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data = map { {filename => $_->filename, link_count => $_->link_count} } @screenshots;
is($jobs->find(99926), undef, 'job deleted');
is_deeply(
    \@screenshot_data,
    [{filename => 'foo', link_count => 1},],
    'link_count for foo decreased, bar completely removed'
) or diag explain \@screenshot_data;

done_testing();
