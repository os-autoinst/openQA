# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(:report_warnings warning);

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Capture::Tiny qw(capture);
use Mojo::Server::Daemon;
use OpenQA::CLI;
use OpenQA::CLI::workers;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '15';
use Date::Format 'time2str';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

my @host = ('--host', $host);

my $cli = OpenQA::CLI->new;
my $workers_cmd = OpenQA::CLI::workers->new;

subtest 'Help' => sub {
    my ($stdout, $stderr, @result) = capture sub { $cli->run('help', 'workers') };
    like $stdout, qr/Usage: openqa-cli workers/, 'help shows usage';
    like $stdout, qr/--unused-days/, 'help describes unused-days option';
};

subtest 'Unknown options' => sub {
    like warning {
        throws_ok { $workers_cmd->run('--bogus') } qr/Usage: openqa-cli workers/, 'unknown option throws usage';
    }, qr/Unknown option: bogus/, 'warning about unknown option';
};

subtest 'Audit hosts' => sub {
    my $workers = $app->schema->resultset('Workers');
    my $now = time;
    my $now_str = time2str('%Y-%m-%d %H:%M:%S', $now, 'UTC');
    my $old = time2str('%Y-%m-%d %H:%M:%S', $now - 20 * 86400, 'UTC');
    my $recent = time2str('%Y-%m-%d %H:%M:%S', $now - 2 * 86400, 'UTC');

    my $stale = $workers->create({id => 950, host => 'stale-cli-host', instance => 1, t_seen => $now_str});
    my $active = $workers->create({id => 951, host => 'active-cli-host', instance => 1, t_seen => $now_str});
    $workers->create({id => 952, host => 'never-cli-host', instance => 1, t_seen => $now_str});

    my $jobs = $app->schema->resultset('Jobs');
    my $j_old
      = $jobs->create({TEST => 'stale-cli', state => 'done', result => 'passed', assigned_worker_id => $stale->id});
    $j_old->update({t_finished => $old});
    my $j_new
      = $jobs->create({TEST => 'active-cli', state => 'done', result => 'passed', assigned_worker_id => $active->id});
    $j_new->update({t_finished => $recent});

    my ($stdout, $stderr, @result) = capture sub { $cli->run('workers', @host) };
    is_deeply \@result, [0], 'workers audit exits 0';
    like $stdout, qr/HOST/, 'table header present';
    like $stdout, qr/stale-cli-host.*never|stale-cli-host.*IDLE/s, 'stale host flagged or shows never';
    like $stdout, qr/never-cli-host.*never.*IDLE/s, 'never host flagged as IDLE';
    unlike $stdout, qr/active-cli-host.*IDLE/, 'active host not flagged as IDLE';

    ($stdout, $stderr, @result) = capture sub { $cli->run('workers', @host, '--unused-days=30') };
    is_deeply \@result, [0], 'workers audit with threshold exits 0';
    unlike $stdout, qr/stale-cli-host.*IDLE/, 'stale host (20d) not flagged when threshold is 30 days';
};

done_testing;
