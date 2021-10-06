#!/usr/bin/env perl
# Copyright 2014-2020 SUSE LLC
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
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;
use Mojo::File 'path';

my $schema  = OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 05-job_modules.pl');
my $t       = Test::Mojo->new('OpenQA::WebAPI');
my $name    = 'installer_timezone';
my $id      = 99938;
my $src_url = "/tests/$id/modules/$name/steps/1/src";
$t->get_ok($src_url)->status_is(200)->content_like(qr|installation/.*$name.pm|i, "$name test source found")
  ->content_like(qr/assert_screen.*timezone/i, "$name test source shown");

subtest 'source view for jobs using VCS based tests' => sub {
    # simulate the job had been triggered with a VCS checkout setting
    my $job       = $schema->resultset('Jobs')->find($id);
    my $vars_file = path($job->result_dir(), 'vars.json');
    $vars_file->remove;
    my $settings_rs = $job->settings_rs;
    my $casedir     = 'https://github.com/me/repo#my/branch';
    $settings_rs->update_or_create({job_id => $id, key => 'CASEDIR', value => $casedir});
    my $expected = qr@github.com/me/repo/blob/my/branch/tests.*/installer_timezone@;
    $t->get_ok($src_url)->status_is(302)->header_like('Location' => $expected);

    subtest 'github treats ".git" as optional extension which needs to be stripped' => sub {
        $casedir = 'https://github.com/me/repo.git#my/branch';
        $settings_rs->find({key => 'CASEDIR'})->update({value => $casedir});
        $t->get_ok($src_url)->status_is(302)->header_like('Location' => $expected);
    };

    subtest 'unique git hash is read from vars.json if existant' => sub {
        $vars_file->spurt('
{
   "TEST_GIT_HASH" : "77b4c9e4bf649d6e489da710b9f08d8008e28af3"
}
');
        $expected = qr@github.com/me/repo/blob/77b4c9e4bf649d6e489da710b9f08d8008e28af3/tests.*/installer_timezone@;
        $t->get_ok($src_url)->status_is(302)->header_like('Location' => $expected);
    };
};

done_testing;
