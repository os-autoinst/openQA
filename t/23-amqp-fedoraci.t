#! /usr/bin/perl

# Copyright (C) 2016-2019 SUSE LLC
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

use Mojo::Base;
use Mojo::IOLoop;

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Client;
use OpenQA::Jobs::Constants;
use OpenQA::Test::Database;
use Test::MockModule;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Mojo::File qw(tempdir path);
use Mojo::JSON qw(decode_json);
use OpenQA::WebAPI::Plugin::AMQP;

my %published;
my $mock_callcount;

my $plugin_mock = Test::MockModule->new('OpenQA::WebAPI::Plugin::AMQP');
$plugin_mock->mock(
    publish_amqp => sub {
        my ($self, $topic, $data) = @_;
        # ignore the non-fedoraci messages, makes it easier to
        # understand the expected call counts
        if ($topic =~ /^ci\./) {
            $mock_callcount++;
            $published{$topic} = $data;
        }
    });

my $schema = OpenQA::Test::Database->new->create();

# this test also serves to test plugin loading via config file
my $conf = << 'EOF';
[global]
plugins=AMQP
base_url=https://openqa.stg.fedoraproject.org
[amqp]
fedora_ci_messages=1
EOF

my $tempdir = tempdir;
$ENV{OPENQA_CONFIG} = $tempdir;
path($ENV{OPENQA_CONFIG})->make_path->child("openqa.ini")->spurt($conf);

my $t = Test::Mojo->new('OpenQA::WebAPI');

# XXX: Test::Mojo loses its app when setting a new ua
# https://github.com/kraih/mojo/issues/598
my $app = $t->app;
$t->ua(
    OpenQA::Client->new(apikey => 'PERCIVALKEY02', apisecret => 'PERCIVALSECRET02')->ioloop(Mojo::IOLoop->singleton));
$t->app($app);

my $settings = {
    DISTRI      => 'Unicorn',
    FLAVOR      => 'pink',
    VERSION     => '42',
    BUILD       => 'Fedora-Rawhide-20180129.n.0',
    TEST        => 'rainbow',
    ISO         => 'whatever.iso',
    DESKTOP     => 'DESKTOP',
    KVM         => 'KVM',
    ISO_MAXSIZE => 1,
    MACHINE     => "RainbowPC",
    ARCH        => 'x86_64',
    SUBVARIANT  => 'workstation'
};

my $expected_artifact = {
    id           => 'Fedora-Rawhide-20180129.n.0',
    iso          => 'whatever.iso',
    type         => 'productmd-compose',
    compose_type => 'nightly',
};

my $expected_contact = {
    name  => 'Fedora openQA',
    team  => 'Fedora QA',
    url   => 'https://openqa.stg.fedoraproject.org',
    docs  => 'https://fedoraproject.org/wiki/OpenQA',
    irc   => '#fedora-qa',
    email => 'qa-devel@lists.fedoraproject.org',
};

my $expected_pipeline = {
    id   => 'openqa.Fedora-Rawhide-20180129.n.0.rainbow.RainbowPC.pink.x86_64',
    name => 'openqa.Fedora-Rawhide-20180129.n.0.rainbow.RainbowPC.pink.x86_64',
};

my $expected_run = {
    url => '',
    log => '',
    id  => '',
};

my $expected_system = {
    os           => 'fedora-42',
    provider     => 'openqa',
    architecture => 'x86_64',
    variant      => 'workstation',
};

my $expected_test = {
    category  => 'validation',
    type      => 'rainbow RainbowPC pink x86_64',
    namespace => 'compose',
    lifetime  => 240,
};

my $expected_error;

my $expected_version = '0.2.1';

sub get_expected {
    my $expected = {
        artifact => $expected_artifact,
        contact  => $expected_contact,
        pipeline => $expected_pipeline,
        run      => $expected_run,
        system   => $expected_system,
        test     => $expected_test,
        version  => $expected_version,
    };
    $expected->{'error'} = $expected_error if ($expected_error);
    return $expected;
}

# create a job via API
my $job;
my $newjob;
subtest 'create job' => sub {
    # reset the call count
    $mock_callcount = 0;
    $t->post_ok("/api/v1/jobs" => form => $settings)->status_is(200);
    ok($job = $t->tx->res->json->{id}, 'got ID of new job');
    ok($mock_callcount == 1,           'mock was called');
    my $publishedref = decode_json($published{'ci.productmd-compose.test.queued'});
    delete $publishedref->{'generated_at'};
    $expected_run = {
        url => "https://openqa.stg.fedoraproject.org/tests/$job",
        log => "https://openqa.stg.fedoraproject.org/tests/$job/file/autoinst-log.txt",
        id  => $job,
    };
    my $expected = get_expected;
    is_deeply($publishedref, $expected, 'job create triggers standardized amqp');
};

subtest 'mark job as done' => sub {
    $mock_callcount = 0;
    $t->post_ok("/api/v1/jobs/$job/set_done")->status_is(200);
    ok($mock_callcount == 1, 'mock was called');
    my $publishedref = decode_json($published{'ci.productmd-compose.test.complete'});
    delete $publishedref->{'generated_at'};
    $expected_test->{'result'} = 'failed';
    delete $expected_test->{'lifetime'};
    my $expected = get_expected;
    is_deeply($publishedref, $expected, 'job done (failed) triggers standardized amqp');
};

subtest 'duplicate and cancel job' => sub {
    $mock_callcount = 0;
    $t->post_ok("/api/v1/jobs/$job/duplicate")->status_is(200);
    $newjob = $t->tx->res->json->{id};
    ok($mock_callcount == 1, 'mock was called');
    my $publishedref = decode_json($published{'ci.productmd-compose.test.queued'});
    delete $publishedref->{'generated_at'};
    $expected_run = {
        clone_of => $job,
        url      => "https://openqa.stg.fedoraproject.org/tests/$newjob",
        log      => "https://openqa.stg.fedoraproject.org/tests/$newjob/file/autoinst-log.txt",
        id       => $newjob,
    };
    $expected_test->{'lifetime'} = 240;
    delete $expected_test->{'result'};
    my $expected = get_expected;
    is_deeply($publishedref, $expected, 'job duplicate triggers standardized amqp');

    $mock_callcount = 0;
    $t->post_ok("/api/v1/jobs/$newjob/cancel")->status_is(200);
    ok($mock_callcount == 1, 'mock was called');
    my $publishedref = decode_json($published{'ci.productmd-compose.test.error'});
    delete $publishedref->{'generated_at'};
    $expected_error = {reason => 'user_cancelled',};
    delete $expected_test->{'lifetime'};
    delete $expected_run->{'clone_of'};
    my $expected = get_expected;
    is_deeply($publishedref, $expected, 'job cancel triggers standardized amqp');
};

subtest 'duplicate and pass job' => sub {
    $mock_callcount = 0;
    $t->post_ok("/api/v1/jobs/$newjob/duplicate")->status_is(200);
    my $newerjob = $t->tx->res->json->{id};
    # explicitly set job as passed
    $t->post_ok("/api/v1/jobs/$newerjob/set_done?result=passed")->status_is(200);
    ok($mock_callcount == 2, 'mock was called');
    my $publishedref = decode_json($published{'ci.productmd-compose.test.complete'});
    delete $publishedref->{'generated_at'};
    $expected_run = {
        url => "https://openqa.stg.fedoraproject.org/tests/$newerjob",
        log => "https://openqa.stg.fedoraproject.org/tests/$newerjob/file/autoinst-log.txt",
        id  => $newerjob,
    };
    $expected_test->{'result'} = 'passed';
    $expected_error = '';
    my $expected = get_expected;
    is_deeply($publishedref, $expected, 'job done (passed) triggers standardized amqp');
};

subtest 'create update job' => sub {
    $mock_callcount = 0;
    diag("Count: $mock_callcount");
    $settings->{BUILD} = 'Update-FEDORA-2018-3c876babb9';
    # let's test HDD_* here too
    $settings->{HDD_1}    = 'disk_f40_minimal.qcow2';
    $settings->{HDD_2}    = 'someotherdisk.img';
    $settings->{BOOTFROM} = 'c';
    delete $settings->{ISO};
    $t->post_ok("/api/v1/jobs" => form => $settings)->status_is(200);
    ok(my $updatejob = $t->tx->res->json->{id}, 'got ID of update job');
    diag("Count: $mock_callcount");
    ok($mock_callcount == 1, 'mock was called');
    my $publishedref = decode_json($published{'ci.fedora-update.test.queued'});
    delete $publishedref->{'generated_at'};
    $expected_artifact = {
        id      => 'FEDORA-2018-3c876babb9',
        type    => 'fedora-update',
        release => '42',
        hdd_1   => 'disk_f40_minimal.qcow2',
        hdd_2   => 'someotherdisk.img',
    };
    $expected_pipeline = {
        id   => 'openqa.Update-FEDORA-2018-3c876babb9.rainbow.RainbowPC.pink.x86_64',
        name => 'openqa.Update-FEDORA-2018-3c876babb9.rainbow.RainbowPC.pink.x86_64',
    };
    $expected_run = {
        url => "https://openqa.stg.fedoraproject.org/tests/$updatejob",
        log => "https://openqa.stg.fedoraproject.org/tests/$updatejob/file/autoinst-log.txt",
        id  => $updatejob,
    };
    $expected_system->{'os'}      = 'fedora-40';
    $expected_test->{'namespace'} = 'update';
    $expected_test->{'lifetime'}  = 240;
    delete $expected_test->{'result'};
    my $expected = get_expected;
    is_deeply($publishedref, $expected, 'update job create triggers standardized amqp');
};

done_testing();
