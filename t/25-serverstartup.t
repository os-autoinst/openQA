# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

BEGIN {
    package OpenQA::FakePlugin::Fuzz;
    use Mojo::Base -base;

    has 'configuration_fields' => sub {
        {
            baz => {
                test => 1
            }};
    };
}

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '8';
use OpenQA::Log 'setup_log';
use OpenQA::Setup;
use OpenQA::Utils;
use Mojolicious;
use Mojo::File qw(tempfile path);

subtest 'Setup logging to file' => sub {
    local $ENV{OPENQA_LOGFILE} = undef;
    my $tempfile = tempfile;
    my $app = Mojolicious->new(config => {logging => {file => $tempfile}});
    setup_log($app);
    $app->attr('log_name', sub { return "test"; });

    my $log = $app->log;
    $log->level('debug');
    $log->error('Just works');
    $log->fatal('Fatal error');
    $log->debug('It works');
    $log->info('Works too');

    my $content = $tempfile->slurp;
    like $content, qr/\[.*\] \[error\] Just works/, 'right error message';
    like $content, qr/\[.*\] \[fatal\] Fatal error/, 'right fatal message';
    like $content, qr/\[.*\] \[debug\] It works/, 'right debug message';
    like $content, qr/\[.*\] \[info\] Works too/, 'right info message';
};

subtest 'Setup logging to STDOUT' => sub {
    local $ENV{OPENQA_LOGFILE} = undef;
    my $buffer = '';
    my $app = Mojolicious->new();
    setup_log($app);
    $app->attr('log_name', sub { return "test"; });
    {
        open my $handle, '>', \$buffer;
        local *STDOUT = $handle;
        my $log = $app->log;
        $log->level('debug');
        $log->error('Just works');
        $log->fatal('Fatal error');
        $log->debug('It works');
        $log->info('Works too');
    }
    like $buffer, qr/\[error\] Just works\n/, 'right error message';
    like $buffer, qr/\[fatal\] Fatal error\n/, 'right fatal message';
    like $buffer, qr/\[debug\] It works\n/, 'right debug message';
    like $buffer, qr/\[info\] Works too\n/, 'right info message';
};

subtest 'Setup logging to file (ENV)' => sub {
    local $ENV{OPENQA_LOGFILE} = tempfile;
    my $app = Mojolicious->new(config => {logging => {file => "/tmp/ignored_foo_bar"}});
    setup_log($app);
    $app->attr('log_name', sub { return "test"; });

    my $log = $app->log;
    $log->level('debug');
    $log->error('Just works');
    $log->fatal('Fatal error');
    $log->debug('It works');
    $log->info('Works too');

    my $content = path($ENV{OPENQA_LOGFILE})->slurp;
    like $content, qr/\[.*\] \[error\] Just works/, 'right error message';
    like $content, qr/\[.*\] \[fatal\] Fatal error/, 'right fatal message';
    like $content, qr/\[.*\] \[debug\] It works/, 'right debug message';
    like $content, qr/\[.*\] \[info\] Works too/, 'right info message';
    ok !-e "/tmp/ignored_foo_bar";

    $app = Mojolicious->new();
    setup_log($app);
    $app->attr('log_name', sub { return "test"; });

    $log = $app->log;
    $log->level('debug');
    $log->error('Just works');
    $log->fatal('Fatal error');
    $log->debug('It works');
    $log->info('Works too');

    $content = path($ENV{OPENQA_LOGFILE})->slurp;
    like $content, qr/\[.*\] \[error\] Just works/, 'right error message';
    like $content, qr/\[.*\] \[fatal\] Fatal error/, 'right fatal message';
    like $content, qr/\[.*\] \[debug\] It works/, 'right debug message';
    like $content, qr/\[.*\] \[info\] Works too/, 'right info message';
};

subtest 'Update configuration from Plugin requirements' => sub {
    use Config::IniFiles;
    use OpenQA::FakePlugin::Foo;
    use OpenQA::FakePlugin::FooBar;
    use OpenQA::FakePlugin::FooBaz;
    use Mojolicious;

    my $config;
    $config->{ini_config} = Config::IniFiles->new();
    $config->{ini_config}->AddSection("auth");
    $config->{ini_config}->AddSection("bar");
    $config->{ini_config}->AddSection("baz");
    $config->{ini_config}->AddSection("bazzer");
    $config->{ini_config}->AddSection("foofoo");

    $config->{ini_config}->newval("auth", "method", "foobar");
    $config->{ini_config}->newval("bar", "foo", "test");
    $config->{ini_config}->newval("baz", "foo", "test2");
    $config->{ini_config}->newval("baz", "test", "bartest");
    $config->{ini_config}->newval("bazzer", "realfoo", "win");
    $config->{ini_config}->newval("foofoo", "is_there", "wohoo");

    # Check if  Config::IniFiles object returns the right values
    is $config->{ini_config}->val("auth", "method"), "foobar",
      "Ini parser contains the right data for OpenQA::FakePlugin::Foo";
    is $config->{ini_config}->val("bar", "foo"), "test",
      "Ini parser contains the right data for OpenQA::FakePlugin::FooBar";
    is $config->{ini_config}->val("baz", "foo"), "test2",
      "Ini parser contains the right data for OpenQA::FakePlugin::FooBaz";
    is $config->{ini_config}->val("baz", "test"), "bartest",
      "Ini parser contains the right data for OpenQA::FakePlugin::Fuzz";
    is $config->{ini_config}->val("bazzer", "realfoo"), "win",
      "Ini parser contains the right data for OpenQA::FakePlugin::Fuzzer";
    is $config->{ini_config}->val("foofoo", "is_there"), "wohoo",
      "Ini parser contains the right data for OpenQA::FakePlugin::FooFoo";

    # inline packages declaration needs to appear as "loaded"
    $INC{"OpenQA/FakePlugin/Fuzz.pm"} = undef;
    $INC{"OpenQA/FakePlugin/Fuzzer.pm"} = undef;
    OpenQA::Setup::update_config($config, "OpenQA::FakePlugin");

    ok exists($config->{auth}->{method}), "Config option exists for OpenQA::FakePlugin::Foo";
    ok exists($config->{bar}->{foo}), "Config option exists for OpenQA::FakePlugin::FooBar";
    ok exists($config->{baz}->{foo}), "Config option exists for OpenQA::FakePlugin::FooBaz";
    ok exists($config->{baz}->{test}), "Config option exists for OpenQA::FakePlugin::Fuzz";
    ok exists($config->{bazzer}->{realfoo}), "Config option exists for OpenQA::FakePlugin::Fuzzer";
    ok !exists($config->{foofoo}->{is_there}), "Config option doesn't exists(yet) for OpenQA::FakePlugin::Foofoo";

    is $config->{auth}->{method}, "foobar", "Right config option for OpenQA::FakePlugin::Foo";
    is $config->{bar}->{foo}, "test", "Right config option for OpenQA::FakePlugin::FooBar";
    is $config->{baz}->{foo}, "test2", "Right config option for OpenQA::FakePlugin::FooBaz";
    is $config->{baz}->{test}, "bartest", "Right config option for OpenQA::FakePlugin::Fuzz";
    is $config->{bazzer}->{realfoo}, "win", "Right config option for OpenQA::FakePlugin::Fuzzer";

    my $app = Mojolicious->new();
    push @{$app->plugins->namespaces}, "OpenQA::FakePlugin";
    $app->config->{ini_config} = $config->{ini_config};
    $app->plugin("FooFoo");
    OpenQA::Setup::update_config($app->config, "OpenQA::FakePlugin");
    is $app->config->{foofoo}->{is_there}, "wohoo", "Right config option for OpenQA::FakePlugin::Foofoo";
};
done_testing();

package OpenQA::FakePlugin::Fuzzer;
use Mojo::Base -base;

sub configuration_fields {
    {
        bazzer => {
            realfoo => 1
        }};
}
