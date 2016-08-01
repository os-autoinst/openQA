#!/usr/bin/env perl -w

# Copyright (C) 2014-2016 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use OpenQA::Utils;
use OpenQA::Test::Case;
use Test::More;
use Test::Mojo;
use Test::Warnings;

my $schema = OpenQA::Test::Case->new->init_data;
my $t      = Test::Mojo->new('OpenQA::WebAPI');
my $rs     = $t->app->db->resultset("Jobs");

is($rs->latest_build, '0091');
is($rs->latest_build(version => 'Factory', distri => 'opensuse'), '0048@0815');
is($rs->latest_build(version => '13.1',    distri => 'opensuse'), '0091');

my @latest = $t->app->db->resultset("Jobs")->latest_jobs;
my @ids = map { $_->id } @latest;
# These two jobs have later clones in the fixture set, so should not appear
ok(grep(!/^(99962|99945)$/, @ids));
# These are the later clones, they should appear
ok(grep(/^99963$/, @ids));
ok(grep(/^99946$/, @ids));

my %settings = (
    DISTRI  => 'Unicorn',
    FLAVOR  => 'pink',
    VERSION => '42',
    BUILD   => '666',
    ISO     => 'whatever.iso',
    MACHINE => "RainbowPC",
    ARCH    => 'x86_64',
);

sub _job_create {
    my $job = $schema->resultset('Jobs')->create_from_settings(@_);
    # reload all values from database so we can check against default values
    $job->discard_changes;
    return $job;
}

subtest 'job with all modules passed => overall is passsed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'A';
    my $job = _job_create(\%_settings);
    for my $i (qw/a b c d/) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::PASSED, 'job result is passed');
};

subtest 'job with at least one module failed => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'B';
    my $job = _job_create(\%_settings);
    for my $i (qw/a b c d/) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => $i eq 'c' ? 'fail' : 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::FAILED, 'job result is failed');
};

subtest 'job with at least one softfailed and rest passed => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'C';
    my $job = _job_create(\%_settings);
    for my $i (qw/a b c/) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'ok', details => [], dents => 1});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with at least one failed module and one softfailed => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'D';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {}});
    $job->update_module('c', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::FAILED, 'job result is failed');
};

subtest 'job with all important modules passed and at least one unimportant failed => overall softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'E';
    my $job = _job_create(\%_settings);
    for my $i (qw/a b c/) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {important => 1}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with important modules passed and at least one softfailed and at least one unimportant failed => overall softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'F';
    my $job = _job_create(\%_settings);
    for my $i (qw/a b/) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {important => 1}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {important => 1}});
    $job->update_module('c', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with one important module failed and at least one unimportant passed => overall failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'G';
    my $job = _job_create(\%_settings);
    for my $i (qw/a b c/) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {important => 0}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {important => 1}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::FAILED, 'job result is failed');
};

subtest 'job with first unimportant and rest softfails => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'H';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {important => 1}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with at least one softfailed => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'I';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {important => 1}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {}});
    $job->update_module('c', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;

    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with no modules => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'I';
    my $job = _job_create(\%_settings);
    $job->update;
    $job->discard_changes;

    is($job->result, OpenQA::Schema::Result::Jobs::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Schema::Result::Jobs::FAILED, 'job result is failed');
};

done_testing();
