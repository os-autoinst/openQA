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
use Mojo::Log;
use Test::Output 'combined_like';
use Test::More;
use Test::Mojo;
use Test::Warnings;

my $schema           = OpenQA::Test::Database->new->create;
my $t                = Test::Mojo->new('OpenQA::WebAPI');
my $screenshots      = $schema->resultset('Screenshots');
my $screenshot_links = $schema->resultset('ScreenshotLinks');
my $jobs             = $schema->resultset('Jobs');

$t->app->log(Mojo::Log->new(level => 'debug'));

# add two screenshots to a job
OpenQA::Schema::Result::ScreenshotLinks::populate_images_to_job($schema, [qw(foo bar)], 99926);
my @screenshot_links = $screenshot_links->search({job_id => 99926})->all;
my @screenshot_ids   = map { $_->screenshot_id } @screenshot_links;
my @screenshots      = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
my @screenshot_data  = map { {filename => $_->filename} } @screenshots;
is(scalar @screenshot_links, 2, '2 screenshot links for job 99926 created');
is_deeply(\@screenshot_data, [{filename => 'foo'}, {filename => 'bar'}], 'two screenshots created')
  or diag explain \@screenshot_data;

# add one of the screenshots to another job
OpenQA::Schema::Result::ScreenshotLinks::populate_images_to_job($schema, [qw(foo)], 99927);
@screenshot_links = $screenshot_links->search({job_id => 99927})->all;
is(scalar @screenshot_links, 1, 'screenshot link for job 99927 created');

# delete the first job
$jobs->find(99926)->delete;
@screenshot_links = $screenshot_links->search({job_id => 99926})->all;
@screenshots      = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data  = map { {filename => $_->filename} } @screenshots;
is($jobs->find(99926),       undef, 'job deleted');
is(scalar @screenshot_links, 0,     'screenshot links for job 99926 deleted');
is_deeply(
    \@screenshot_data,
    [{filename => 'foo'}, {filename => 'bar'}],
    'screenshot not directly cleaned up after deleting job'
) or diag explain \@screenshot_data;

# limit job results (which involves deleting unused screenshots)
combined_like(
    sub { OpenQA::Task::Job::Limit::_limit($t->app); },
    qr/removing screenshot bar/,
    'removing screenshot logged'
);
@screenshots = $screenshots->search({id => {-in => \@screenshot_ids}})->search({}, {order_by => 'id'});
@screenshot_data = map { {filename => $_->filename} } @screenshots;
is_deeply(\@screenshot_data, [{filename => 'foo'}], 'foo still present (used in 99927), bar removed (no longer used)')
  or diag explain \@screenshot_data;

done_testing();
