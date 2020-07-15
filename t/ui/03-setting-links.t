#!/usr/bin/env perl
# SUSE's openQA tests
#
# Copyright © 2020 SUSE LLC
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

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use Mojo::File qw(path tempfile);

my $schema = OpenQA::Test::Case->new->init_data;
# setup openqa.ini with job_settings_ui
$ENV{OPENQA_CONFIG} = "t/data/03-setting-links";
my $t   = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;

$t->app($app);
# t/data holds test files that simulates setting files that can be found in test distributions
$ENV{OPENQA_BASEDIR} = 't/data';
my $job_id  = 99938;
my $uri_dir      = "/tests/$job_id/foo/foo.txt";
my $uri_data_dir = "/tests/$job_id/bar/foo.txt";
$t->get_ok($uri_dir)->status_is(200)
  ->content_like(qr|test|i, "setting file source found from the root of the test distribution");
$t->get_ok($uri_data_dir)->status_is(200)->content_like(qr|test|i, "setting file source found in default_data_dir");

subtest 'view source for setting links when test is VCS based' => sub {
    # simulate the job had been triggered with a VCS checkout setting
    # similar with what Test::src does
    my $job       = $schema->resultset('Jobs')->find($job_id);
    my $vars_file = path($job->result_dir(), 'vars.json');
    $vars_file->remove;
    my $settings_rs = $job->settings_rs;
    my $casedir     = 'https://github.com/me/repo#my/branch';
    $settings_rs->update_or_create({job_id => $job_id, key => 'CASEDIR', value => $casedir});
    my $expected_in_root_path = qr@github.com/me/repo/blob/my/branch/foo/foo.txt@;
    $t->get_ok($uri_dir)->status_is(302)->header_like('Location' => $expected_in_root_path);
    my $expected_in_default_data_dir = qr@github.com/me/repo/blob/my/branch/data/bar/foo.txt@;
    $t->get_ok($uri_data_dir)->status_is(302)->header_like('Location' => $expected_in_default_data_dir);

    subtest 'github treats ".git" as optional extension which needs to be stripped' => sub {
        $casedir = 'https://github.com/me/repo.git#my/branch';
        $settings_rs->find({key => 'CASEDIR'})->update({value => $casedir});
        $t->get_ok($uri_dir)->status_is(302)->header_like('Location' => $expected_in_root_path);
    };

    subtest 'unique git hash is read from vars.json if existent' => sub {
        $vars_file->spurt(
            '{
                                  "TEST_GIT_HASH" : "77b4c9e4bf649d6e489da710b9f08d8008e28af3"
            }'
        );
        my $expected = qr@github.com/me/repo/blob/77b4c9e4bf649d6e489da710b9f08d8008e28af3/foo/foo.txt@;
        $t->get_ok($uri_dir)->status_is(302)->header_like('Location' => $expected);
    };
};

done_testing;
