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
    $ENV{OPENQA_TEST_IPC} = 1;
}

use strict;
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Case;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Mojo::IOLoop::ReadWriteProcess;
use OpenQA::Test::Utils 'redirect_output';
use OpenQA::Parser::Result::OpenQA;
use OpenQA::Parser::Result::Test;
use OpenQA::Parser::Result::Output;

my $schema = OpenQA::Test::Case->new->init_data;
my $t      = Test::Mojo->new('OpenQA::WebAPI');
my $rs     = $t->app->db->resultset("Jobs");

is($rs->latest_build, '0091');
is($rs->latest_build(version => 'Factory', distri => 'opensuse'), '0048@0815');
is($rs->latest_build(version => '13.1',    distri => 'opensuse'), '0091');

my @latest = $rs->latest_jobs;
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

subtest 'initial job module statistics' => sub {
    # Those counters are not directly hardcoded in the jobs table of the fixtures.
    # Instead, the counters are automatically incremented when initializing the
    # job module fixtures.
    my $job = $rs->find(99946);
    is($job->passed_module_count,     28, 'number of passed modules');
    is($job->softfailed_module_count, 1,  'number of softfailed modules');
    is($job->failed_module_count,     1,  'number of failed modules');
    is($job->skipped_module_count,    0,  'number of skipped modules');
};

subtest 'job with all modules passed => overall is passsed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'A';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c d)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result,                  OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    is($job->passed_module_count,     4,                               'number of passed modules incremented');
    is($job->softfailed_module_count, 0,                               'number of softfailed modules not incremented');
    is($job->failed_module_count,     0,                               'number of failed modules not incremented');
    is($job->skipped_module_count,    0,                               'number of skipped modules not incremented');
};

subtest 'job with one skipped module => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'A';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'e', category => 'e', script => 'e', flags => {}});
    $job->update_module('e', {result => 'none', details => []});
    for my $i (qw(a b c d)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result,                  OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->passed_module_count,     4,                               'number of passed modules incremented');
    is($job->softfailed_module_count, 0,                               'number of softfailed modules not incremented');
    is($job->failed_module_count,     0,                               'number of failed modules not incremented');
    is($job->skipped_module_count,    1,                               'number of skipped modules incremented');
};

subtest 'job with at least one module failed => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'B';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c d)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => $i eq 'c' ? 'fail' : 'ok', details => []});
    }
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result,                  OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is($job->passed_module_count,     3,                               'number of passed modules incremented');
    is($job->softfailed_module_count, 0,                               'number of softfailed modules not incremented');
    is($job->failed_module_count,     1,                               'number of failed modules incremented');
    is($job->skipped_module_count,    0,                               'number of skipped modules not incremented');
};

subtest 'job with at least one softfailed and rest passed => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'C';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {}});
    $job->update_module('d', {result => 'ok', details => [], dents => 1});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result,                  OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    is($job->passed_module_count,     3,                                   'number of passed modules incremented');
    is($job->softfailed_module_count, 1,                                   'number of softfailed modules incremented');
    is($job->failed_module_count,     0,                                   'number of failed modules not incremented');
    is($job->skipped_module_count,    0,                                   'number of skipped modules not incremented');
};

subtest 'Create custom job module' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'TEST1';
    my $job    = _job_create(\%_settings);
    my $result = OpenQA::Parser::Result::OpenQA->new(
        details => [{text => "Test-CUSTOM.txt", title => 'CUSTOM'}],
        name    => 'random',
        result  => 'fail',
        test    => OpenQA::Parser::Result::Test->new(name => 'CUSTOM', category => 'w00t!'));
    my $output = OpenQA::Parser::Result::Output->new(file => 'Test-CUSTOM.txt', content => 'Whatever!');

    $job->custom_module($result => $output);
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');

    is(($job->failed_modules)->[0], 'CUSTOM');
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
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
};

subtest 'job with all modules passed and at least one ignore_failure failed => overall passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'E';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {ignore_failure => 1}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
};

subtest
'job with important modules passed and at least one softfailed and at least one ignore_failure failed => overall softfailed'
  => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'F';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {}});
    $job->update_module('c', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {ignore_failure => 1}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
  };

subtest
'job with one "important" (old flag we now ignore) module failed and at least one ignore_failure passed => overall failed'
  => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'G';
    my $job = _job_create(\%_settings);
    for my $i (qw(a b c)) {
        $job->insert_module({name => $i, category => $i, script => $i, flags => {ignore_failure => 1}});
        $job->update_module($i, {result => 'ok', details => []});
    }
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {important => 1}});
    $job->update_module('d', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
  };

subtest 'job with first ignore_failure failed and rest softfails => overall is softfailed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'H';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {important => 1}});
    $job->update_module('b', {result => 'ok', details => [], dents => 1});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with one ignore_failure pass => overall is passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'H';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
};

subtest 'job with one ignore_failure fail => overall is passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'H';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
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

    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
};

subtest 'job with no modules => overall is failed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'J';
    my $job = _job_create(\%_settings);
    $job->update;
    $job->discard_changes;

    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
};

subtest 'carry over for soft-fails' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'K';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    $job->comments->create({text => 'bsc#101', user_id => 99901});

    $_settings{BUILD} = '667';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is(0, $job->comments, 'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::SOFTFAILED, 'job result is softfailed');
    is(1, $job->comments, 'one comment');
    like($job->comments->first->text, qr/\Qbsc#101\E/, 'right take over');

    $_settings{BUILD} = '668';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update_module('a', {result => 'ok', details => [], dents => 1});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is(0, $job->comments, 'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is(0, $job->comments, 'no takeover');

};

subtest 'carry over for ignore_failure modules' => sub {
    my %_settings = %settings;
    $_settings{TEST}  = 'K';
    $_settings{BUILD} = '669';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    $job->comments->create({text => 'bsc#101', user_id => 99901});

    $_settings{BUILD} = '670';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is(0, $job->comments, 'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
    is(1, $job->comments, 'one comment');
    like($job->comments->first->text, qr/\Qbsc#101\E/, 'right take over');

    $_settings{BUILD} = '671';
    $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {ignore_failure => 1}});
    $job->update_module('a', {result => 'fail', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {}});
    $job->update_module('b', {result => 'fail', details => []});
    $job->update;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    is(0, $job->comments, 'no comment');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::FAILED, 'job result is failed');
    is(0, $job->comments, 'no takeover');

};

subtest 'job with only important passes => overall is passed' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'L';
    my $job = _job_create(\%_settings);
    $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {important => 1}});
    $job->update_module('a', {result => 'ok', details => []});
    $job->insert_module({name => 'b', category => 'b', script => 'b', flags => {important => 1}});
    $job->update_module('b', {result => 'ok', details => []});
    $job->insert_module({name => 'c', category => 'c', script => 'c', flags => {important => 1}});
    $job->update_module('c', {result => 'ok', details => []});
    $job->insert_module({name => 'd', category => 'd', script => 'd', flags => {important => 1}});
    $job->update_module('d', {result => 'ok', details => []});
    $job->update;
    $job->discard_changes;

    is($job->result, OpenQA::Jobs::Constants::NONE, 'result is not yet set');
    $job->done;
    $job->discard_changes;
    is($job->result, OpenQA::Jobs::Constants::PASSED, 'job result is passed');
};

sub job_is_linked {
    my ($job) = @_;
    $job->discard_changes;
    my $comments = $job->comments;
    while (my $c = $comments->next) {
        if ($c->label eq 'linked') {
            return 1;
        }
    }
    return 0;
}

subtest 'job is marked as linked if accessed from recognized referal' => sub {
    $t->app->config->{global}->{recognized_referers}
      = ['test.referer.info', 'test.referer1.info', 'test.referer2.info', 'test.referer3.info'];
    my %_settings = %settings;
    $_settings{TEST} = 'refJobTest';
    my $job    = _job_create(\%_settings);
    my $linked = job_is_linked($job);
    is($linked, 0, 'new job is not linked');
    $t->get_ok('/tests/' . $job->id => {Referer => 'http://test.referer.info'})->status_is(200);
    $linked = job_is_linked($job);
    is($linked, 1, 'job linked after accessed from known referer');

    $_settings{TEST} = 'refJobTest-step';
    $job = _job_create(\%_settings);

    my $module = $job->insert_module({name => 'a', category => 'a', script => 'a', flags => {}});
    $job->update;
    $linked = job_is_linked($job);
    is($linked, 0, 'new job is not linked');
    $t->get_ok('/tests/' . $job->id . '/modules/' . $module->id . '/steps/1' => {Referer => 'http://test.referer.info'})
      ->status_is(302);
    $linked = job_is_linked($job);
    is($linked, 1, 'job linked after accessed from known referer');
};

subtest 'job is not marked as linked if accessed from unrecognized referal' => sub {
    $t->app->config->{global}->{recognized_referers}
      = ['test.referer.info', 'test.referer1.info', 'test.referer2.info', 'test.referer3.info'];
    my %_settings = %settings;
    $_settings{TEST} = 'refJobTest2';
    my $job    = _job_create(\%_settings);
    my $linked = job_is_linked($job);
    is($linked, 0, 'new job is not linked');
    $t->get_ok('/tests/' . $job->id => {Referer => 'http://unknown.referer.info'})->status_is(200);
    $linked = job_is_linked($job);
    is($linked, 0, 'job not linked after accessed from unknown referer');
};

subtest 'job set_running()' => sub {
    my %_settings = %settings;
    $_settings{TEST} = 'L';
    my $job = _job_create(\%_settings);
    $job->update({state => OpenQA::Jobs::Constants::ASSIGNED});
    is($job->set_running, 1, 'job was set to running');
    is($job->state, OpenQA::Jobs::Constants::RUNNING, 'job state is now on running');
    $job->update({state => OpenQA::Jobs::Constants::RUNNING});
    is($job->set_running, 1, 'job already running');
    is($job->state, OpenQA::Jobs::Constants::RUNNING, 'job state is now on running');
    $job->update({state => 'foobar'});
    is($job->set_running, 0,        'job not set to running');
    is($job->state,       'foobar', 'job state is foobar');
};


use OpenQA::Worker::Common 'get_timer';
use OpenQA::Worker::Jobs;
use OpenQA::Worker::Pool;
use File::Spec::Functions;
no warnings 'redefine';
sub OpenQA::Worker::Jobs::engine_workit {
    return {child => Mojo::IOLoop::ReadWriteProcess->new};
}
my $alive = 1;
sub Mojo::IOLoop::ReadWriteProcess::is_running {
    return $alive;
}

sub OpenQA::Worker::Jobs::_stop_job {
    return;
}

sub _check_timers {
    my ($is_set) = @_;
    my $set = 0;
    for my $t (qw(update_status job_timeout)) {
        my $timer = get_timer($t);
        if ($timer) {
            $set += 1 if Mojo::IOLoop->singleton->reactor->{timers}{$timer->[0]};
        }
    }
    if ($is_set) {
        is($set, 2, 'timers set');
    }
    else {
        is($set, 0, 'timers not set');
    }

}

subtest 'job timers are added after start job and removed after stop job' => sub {
    _check_timers(0);
    $OpenQA::Worker::Jobs::job = {id => 1, settings => {NAME => 'test_job'}};
    OpenQA::Worker::Jobs::start_job('example.host');
    _check_timers(1);

    my $exception = 1;
    eval {
        OpenQA::Worker::Jobs::stop_job('done');
        $exception = 0;
    };
    ok(!$exception, 'Pool check qemu done');
    _check_timers(0);
};

subtest 'Old logs are deleted when nocleanup is set' => sub {
    use OpenQA::Worker::Pool 'clean_pool';
    use OpenQA::Worker::Common qw($nocleanup $pooldir);
    $nocleanup = 1;
    $pooldir   = Mojo::File->tempdir('pool');

    $pooldir->child('autoinst-log.txt')->spurt('Hello Mojo!');
    $OpenQA::Worker::Jobs::job = {id => 1, settings => {NAME => 'test_job'}};
    OpenQA::Worker::Jobs::start_job('example.host');
    ok(!-e $pooldir->child('autoinst-log.txt'), 'autoinst-log.txt file has been deleted');
    ok(-e $pooldir->child('worker-log.txt'),    'Worker log is there');
    $nocleanup = 0;
    $pooldir   = undef;
};

$t->get_ok('/t99946')->status_is(302)->header_like(Location => qr{tests/99946});

subtest 'delete job assigned as last use for asset' => sub {
    my $assets     = $t->app->db->resultset('Assets');
    my $some_job   = $rs->first;
    my $some_asset = $assets->first;
    my $asset_id   = $some_asset->id;

    # let the asset reference a job
    $some_asset->update({last_use_job_id => $some_job->id});

    # delete that job
    ok($some_job->delete,      'job deletion ok');
    ok(!$some_job->in_storage, 'job no in storage anymore');

    # assert whether asset is still present
    $some_asset = $assets->find($asset_id);
    ok($some_asset, 'asset still exists');
    is($some_asset->last_use_job_id, undef, 'last job unset');
};

subtest 'check dead qemu' => sub {
    use OpenQA::Worker::Pool 'clean_pool';
    use OpenQA::Worker::Common qw($nocleanup $pooldir);
    $nocleanup = 0;

    $pooldir = Mojo::File->tempdir('pool');
    my $qemu_pid_fh = Mojo::File->new(catfile($pooldir), 'qemu.pid')->open('>');
    print $qemu_pid_fh '999999999999999999';
    close $qemu_pid_fh;

    my $exception = 1;
    eval {
        clean_pool();
        $exception = 0;
    };
    ok(!$exception, 'dead qemu bogus pid');

    $qemu_pid_fh = Mojo::File->new(catfile($pooldir), 'qemu.pid')->open('>');
    print $qemu_pid_fh $$;
    close $qemu_pid_fh;
    $exception = 1;
    eval {
        clean_pool();
        $exception = 0;
    };
    ok(!$exception, 'dead qemu bogus exec');
};

subtest 'check dead children stop job' => sub {
    sub OpenQA::Worker::Jobs::api_call { 1; }
    use OpenQA::Utils;
    my $log = add_log_channel('autoinst', level => 'debug', default => 'append');
    my @messages;
    $log->on(
        message => sub {
            my ($log, $level, @lines) = @_;
            push @messages, @lines;
        });

    $alive = 0;

    eval { OpenQA::Worker::Jobs::_stop_job_2('dead_children'); };

    like($messages[2], qr/result: dead_children/, 'dead children match exception');
};

subtest 'job PARALLEL_WITH' => sub {

    use OpenQA::Scheduler::Scheduler;
    use OpenQA::Schema::Result::JobDependencies;

    my %_settings = %settings;
    $_settings{TEST} = 'A';
    #  $_settings{PARALLEL_WITH}    = 'B,C,D';
    my $jobA = _job_create(\%_settings);

    %_settings                = %settings;
    $_settings{TEST}          = 'B';
    $_settings{PARALLEL_WITH} = 'A,C,D';
    my $jobB = _job_create(\%_settings);

    %_settings                = %settings;
    $_settings{TEST}          = 'C';
    $_settings{PARALLEL_WITH} = 'A,B,D';
    my $jobC = _job_create(\%_settings);

    %_settings                = %settings;
    $_settings{TEST}          = 'D';
    $_settings{PARALLEL_WITH} = 'A,B, C ';    # Let's commit an error on purpose :)
    my $jobD = _job_create(\%_settings);

    %_settings                = %settings;
    $_settings{TEST}          = 'E';
    $_settings{PARALLEL_WITH} = 'A,B,C';
    my $jobE = _job_create(\%_settings);

    %_settings                = %settings;
    $_settings{TEST}          = 'H';
    $_settings{PARALLEL_WITH} = 'B,C,D';
    my $jobH = _job_create(\%_settings);

    $jobA->children->create(
        {
            child_job_id => $jobB->id,
            dependency   => OpenQA::Schema::Result::JobDependencies->PARALLEL,
        });
    $jobA->children->create(
        {
            child_job_id => $jobC->id,
            dependency   => OpenQA::Schema::Result::JobDependencies->PARALLEL,
        });
    $jobA->children->create(
        {
            child_job_id => $jobD->id,
            dependency   => OpenQA::Schema::Result::JobDependencies->PARALLEL,
        });
    $jobA->children->create(
        {
            child_job_id => $jobE->id,
            dependency   => OpenQA::Schema::Result::JobDependencies->PARALLEL,
        });
    %_settings = %settings;
    $_settings{TEST} = 'F';
    my $jobF = _job_create(\%_settings);

    %_settings = %settings;
    $_settings{TEST} = 'G';
    my $jobG = _job_create(\%_settings);

    # A wants to be in the cluster while being assigned!
    my @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobA->to_hash, $jobF->to_hash);
    is @res, 1;
    is $res[0]->{id}, $jobF->id() or die diag explain $jobA->to_hash;

    # All are going
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobA->to_hash, $jobB->to_hash, $jobC->to_hash, $jobD->to_hash,
        $jobE->to_hash, $jobF->to_hash);
    is @res, 6;

    # Only F doesn't belong to any cluster
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobA->to_hash, $jobC->to_hash, $jobD->to_hash, $jobE->to_hash,
        $jobF->to_hash);
    is @res, 1;
    is $res[0]->{id}, $jobF->id();

    # Only E and F doesn't care about clusters, and we are not about to start D
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobA->to_hash, $jobC->to_hash, $jobB->to_hash, $jobE->to_hash,
        $jobF->to_hash);
    is @res, 2;
    is $res[0]->{id}, $jobE->id();
    is $res[1]->{id}, $jobF->id();

    # Only E and F doesn't care about clusters, and we are not about to start D
    # G does care about clusters, but didn't specified PARALLEL_WITH tests to rely upon
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobA->to_hash, $jobC->to_hash, $jobB->to_hash, $jobE->to_hash,
        $jobF->to_hash, $jobG->to_hash);
    is @res, 3;
    is $res[0]->{id}, $jobE->id();
    is $res[1]->{id}, $jobF->id();
    is $res[2]->{id}, $jobG->id();

    # All are going
    @res = OpenQA::Scheduler::Scheduler::filter_jobs(
        $jobA->to_hash, $jobB->to_hash, $jobC->to_hash, $jobD->to_hash,
        $jobE->to_hash, $jobF->to_hash, $jobG->to_hash
    );
    is @res, 7;

    # just few that requires cluster are going, but since they want to be together, they are not
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobA->to_hash, $jobB->to_hash, $jobC->to_hash);
    is @res, 0;

    # just few that requires cluster are going, but since they want to be together, they are not
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobH->to_hash, $jobC->to_hash);
    is @res, 0;

    # just few that requires cluster are going, but since they want to be together, they are not
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobH->to_hash, $jobC->to_hash, $jobB->to_hash);
    is @res, 0;

    # just few that requires cluster are going, but since they want to be together, they are not
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobH->to_hash, $jobB->to_hash, $jobD->to_hash);
    is @res, 0;

    # A requires E, so it is not going
    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobH->to_hash, $jobC->to_hash, $jobB->to_hash, $jobA->to_hash,
        $jobD->to_hash);
    is @res, 4 or die diag explain \@res;


    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobH->to_hash, $jobC->to_hash, $jobE->to_hash, $jobB->to_hash,
        $jobA->to_hash, $jobD->to_hash);
    is @res, 6 or die diag explain \@res;

    %_settings                = %settings;
    $_settings{TEST}          = 'J';
    $_settings{PARALLEL_WITH} = 'K,L';
    my $jobJ = _job_create(\%_settings);

    %_settings                = %settings;
    $_settings{TEST}          = 'K';
    $_settings{PARALLEL_WITH} = 'J,L';
    my $jobK = _job_create(\%_settings);

    %_settings                = %settings;
    $_settings{TEST}          = 'L';
    $_settings{PARALLEL_WITH} = 'J,K';
    my $jobL = _job_create(\%_settings);

    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobJ->to_hash, $jobK->to_hash);
    is @res, 0 or die diag explain \@res;

    $jobL->update({state => OpenQA::Jobs::Constants::RUNNING});

    @res = OpenQA::Scheduler::Scheduler::filter_jobs($jobJ->to_hash, $jobK->to_hash);
    is @res, 2 or die diag explain \@res;

    my @e = ([], [qw(a b c)], [qw(d e f)]);
    @res = OpenQA::Scheduler::Scheduler::filter_jobs(@e);
    is_deeply \@res, \@e or die diag explain \@res;
};

done_testing();
