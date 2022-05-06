# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(:report_warnings warning);
use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Capture::Tiny qw(capture capture_stdout);
use Mojo::Server::Daemon;
use Mojo::File qw(tempdir tempfile);
use OpenQA::CLI;
use OpenQA::CLI::clone;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');

# Mock WebAPI with extra test routes
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

# Default options for mock server
my @host = ('--host', $host);

# Default options for authentication tests
my @auth = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', @host);

my $cli = OpenQA::CLI->new;
my $cmd = OpenQA::CLI::clone->new;
my $dir = tempdir("/tmp/$FindBin::Script-XXXX");

subtest 'Help' => sub {
    my ($stdout, @result) = capture_stdout sub { $cli->run('help', 'clone') };
    like $stdout, qr/Usage: openqa-cli clone/, 'help';
};

subtest 'Hosts' => sub {
    my ($stdout, $stderr, @result) = capture_stdout sub { $cmd->run(@auth, @host, "$host/t99937") };
    like $stdout, qr/XXX/, 'XXX';

    ($stdout, $stderr, @result) = capture_stdout sub { $cmd->run(@auth, '--within-instance', "$host/t99937") };
    like $stdout, qr/XXX/, 'XXX';

    eval { $cmd->run('--osd', 'http://openqa.example.com/t123456') };
    like $@, qr/Usage: openqa-cli clone/, 'usage';
    is $cmd->host, 'http://openqa.suse.de', 'host';

    eval { $cmd->run('--osd', 'http://openqa.example.com/t123456') };
    like $@, qr/Usage: openqa-cli clone/, 'usage';
    is $cmd->host, 'https://openqa.opensuse.org', 'host';
};

done_testing();
