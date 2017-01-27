#! /usr/bin/perl

# Copyright (C) 2016-2017 SUSE LLC
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

use Cwd qw(abs_path getcwd);

BEGIN {
    unshift @INC, 'lib';
    $ENV{OPENQA_CONFIG}  = 't/full-stack.d/config';
    $ENV{OPENQA_BASEDIR} = abs_path('t/full-stack.d');
    # DO NOT SET OPENQA_IPC_TEST HERE
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Data::Dumper;
use IO::Socket::INET;
use Cwd qw(abs_path getcwd);
use POSIX '_exit';

# optional but very useful
eval 'use Test::More::Color';
eval 'use Test::More::Color "foreground"';

use File::Path qw(make_path remove_tree);
use Module::Load::Conditional 'can_load';

plan skip_all => "set FULLSTACK=1 (be careful)" unless $ENV{FULLSTACK};

my $workerpid;
my $wspid;
my $schedulerpid;

sub turn_down_stack {
    if ($workerpid) {
        kill TERM => $workerpid;
        waitpid($workerpid, 0);
    }

    if ($wspid) {
        kill TERM => $wspid;
        waitpid($wspid, 0);
    }

    if ($schedulerpid) {
        kill TERM => $schedulerpid;
        waitpid($schedulerpid, 0);
    }

}

use t::ui::PhantomTest;

# skip if phantomjs or Selenium::Remote::WDKeys isn't available
use IPC::Cmd 'can_run';
if (!can_run('phantomjs') || !can_load(modules => {'Selenium::PhantomJS' => undef,})) {
    return undef;
}

unlink('t/full-stack.d/openqa/db/db.sqlite');
ok(open(my $conf, '>', 't/full-stack.d/config/database.ini'));
print $conf <<EOC;
[production]
dsn = dbi:SQLite:dbname=t/full-stack.d/openqa/db/db.sqlite
on_connect_call = use_foreign_keys
on_connect_do = PRAGMA synchronous = OFF
sqlite_unicode = 1
EOC
close($conf);
is(system("perl ./script/initdb --init_database"), 0);
# make sure the assets are prefetched
ok(Mojolicious::Commands->start_app('OpenQA::WebAPI', 'eval', '1+0'));

$schedulerpid = fork();
if ($schedulerpid == 0) {
    use OpenQA::Scheduler;
    OpenQA::Scheduler::run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);
}

# we don't want no fixtures
my $mojoport = t::ui::PhantomTest::start_app(sub { });
ok($mojoport);
my $driver = t::ui::PhantomTest::start_phantomjs($mojoport);
ok($driver);

# remove_tree dies on error
remove_tree('t/full-stack.d/openqa/testresults/');
ok(make_path('t/full-stack.d/openqa/testresults/'));
remove_tree('t/full-stack.d/openqa/images/');

$driver->title_is("openQA", "on main page");
is($driver->find_element_by_id('user-action')->get_text(), 'Login', "noone logged in");
$driver->find_element_by_link_text('Login')->click();
# we're back on the main page
$driver->title_is("openQA", "back on main page");
# but ...

my $wsport = $mojoport + 1;
$wspid = fork();
if ($wspid == 0) {
    $ENV{MOJO_LISTEN} = "http://127.0.0.1:$wsport";
    use OpenQA::WebSockets;
    OpenQA::WebSockets::run;
    Devel::Cover::report() if Devel::Cover->can('report');
    _exit(0);
}
else {
    # wait for websocket server
    my $wait = time + 20;
    while (time < $wait) {
        my $t      = time;
        my $socket = IO::Socket::INET->new(
            PeerHost => '127.0.0.1',
            PeerPort => $wsport,
            Proto    => 'tcp'
        );
        last if $socket;
        sleep 1 if time - $t < 1;
    }
}

my $connect_args = "--apikey=1234567890ABCDEF --apisecret=1234567890ABCDEF --host=http://localhost:$mojoport";

make_path('t/full-stack.d/openqa/share/factory/iso');
unlink('t/full-stack.d/openqa/share/factory/iso/Core-7.2.iso');
symlink(abs_path("../os-autoinst/t/data/Core-7.2.iso"), "t/full-stack.d/openqa/share/factory/iso/Core-7.2.iso")
  || die "can't symlink";

make_path('t/full-stack.d/openqa/share/tests');
unlink('t/full-stack.d/openqa/share/tests/tinycore');
symlink(abs_path('../os-autoinst/t/data/tests/'), 't/full-stack.d/openqa/share/tests/tinycore')
  || die "can't symlink";

sub client_output {
    my ($args) = @_;
    open(my $client, "perl ./script/client $connect_args $args|");
    my $out;
    while (<$client>) {
        $out .= $_;
    }
    close($client);
    return $out;
}

sub client_call {
    my ($args, $expected_out, $desc) = @_;
    my $out = client_output $args;
    is($?, 0, "Client $args succeeded");
    if ($expected_out) {
        like($out, $expected_out, $desc);
    }
}

# schedule job
client_call('jobs post ISO=Core-7.2.iso DISTRI=tinycore ARCH=i386 QEMU=i386 QEMU_NO_KVM=1 '
      . 'FLAVOR=flavor BUILD=1 MACHINE=coolone QEMU_NO_TABLET=1 '
      . 'QEMU_NO_FDC_SET=1 CDMODEL=ide-cd HDDMODEL=ide-drive VERSION=1 TEST=core PUBLISH_HDD_1=core-hdd.qcow2');

# verify it's displayed scheduled
$driver->find_element_by_link_text('All Tests')->click();
$driver->title_is('openQA: Test results', 'tests followed');
like($driver->get_page_source(), qr/\Q<h2>1 scheduled jobs<\/h2>\E/, '1 job scheduled');
wait_for_ajax;

my $job_name = 'tinycore-1-flavor-i386-Build1-core@coolone';
$driver->find_element_by_link_text('core@coolone')->click();
$driver->title_is("openQA: $job_name test results", 'scheduled test page');
like($driver->find_element('#result-row .panel-body')->get_text(), qr/State: scheduled/, 'test 1 is scheduled');
javascript_console_is_empty;

sub start_worker {
    $workerpid = fork();
    if ($workerpid == 0) {
        exec("perl ./script/worker --instance=1 $connect_args --isotovideo=../os-autoinst/isotovideo --verbose");
        die "FAILED TO START WORKER";
    }
}

start_worker;

sub wait_for_result_panel {
    my ($result_panel, $desc) = @_;

    for (my $count = 0; $count < 130; $count++) {
        last if $driver->find_element('#result-row .panel-body')->get_text() =~ $result_panel;
        sleep 1;
    }
    javascript_console_is_empty;
    $driver->refresh();
    like($driver->find_element('#result-row .panel-body')->get_text(), $result_panel, $desc);
}

sub wait_for_job_running {
    wait_for_result_panel qr/State: running/, 'job is running';
}
wait_for_job_running;
wait_for_result_panel qr/Result: passed/, 'test 1 is passed';

ok(-s "t/full-stack.d/openqa/testresults/00000/00000001-$job_name/autoinst-log.txt", 'log file generated');
ok(-s 't/full-stack.d/openqa/share/factory/hdd/core-hdd.qcow2',                      'image of hdd uploaded');

my $post_group_res = client_output "job_groups post name='New job group'";
my $group_id       = ($post_group_res =~ qr/{ *id *=> *([0-9]*) *}\n/);
ok($group_id, 'regular post via client script');
client_call(
    "jobs/1 put --json-data '{\"group_id\": $group_id}'",
    qr/\Q{ job_id => 1 }\E/,
    'send JSON data via client script'
);
client_call('jobs/1', qr/group_id *=> *$group_id/, 'group has been altered correctly');

client_call('jobs/1/restart post', qr{\Qtest_url => ["/tests/2\E}, 'client returned new test_url');
$driver->refresh();
like($driver->find_element('#result-row .panel-body')->get_text(), qr/Cloned as 2/, 'test 1 is restarted');
$driver->click_element_ok('2', 'link_text');

wait_for_job_running;
# now kill the worker
kill TERM => $workerpid;
is(waitpid($workerpid, 0), $workerpid, 'WORKER is done');
$workerpid = undef;

wait_for_result_panel qr/Result: incomplete/, 'test 2 crashed';
like(
    $driver->find_element('#result-row .panel-body')->get_text(),
    qr/Cloned as 3/,
    'test 2 is restarted by killing worker'
);

kill_phantom;
turn_down_stack;
done_testing;

# in case it dies
END {
    kill_phantom;
    turn_down_stack;
    $? = 0;
}

