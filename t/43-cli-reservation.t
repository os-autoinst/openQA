# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(:report_warnings warning);

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Capture::Tiny qw(capture capture_stdout);
use Mojo::Server::Daemon;
use OpenQA::CLI;
use OpenQA::CLI::reservation;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '15';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 02-workers.pl 03-users.pl');

# Mock WebAPI using the real application
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

my @host = ('--host', $host);
my @auth_op = ('--apikey', 'PERCIVALKEY02', '--apisecret', 'PERCIVALSECRET02', @host);
my @auth_admin = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', @host);

my $cli = OpenQA::CLI->new;
my $reservation = OpenQA::CLI::reservation->new;

subtest 'Help' => sub {
    my ($stdout, $stderr, @result) = capture sub { $cli->run('help', 'reservation') };
    like $stdout, qr/Usage: openqa-cli reservation/, 'help';
    like $stdout, qr/--class/, 'help describes class option';
    like $stdout, qr/--comment/, 'help describes comment option';
    like $stdout, qr/--duration/, 'help describes duration option';
    like $stdout, qr/--force/, 'help describes force option';
    like $stdout, qr/--release/, 'help describes release option';
};

subtest 'Unknown options' => sub {
    like warning {
        throws_ok { $reservation->run('--unknown') } qr/Usage: openqa-cli reservation/, 'unknown option';
    }, qr/Unknown option: unknown/, 'warning about unknown option';
};

subtest 'Defaults' => sub {
    is $reservation->apibase, '/api/v1', 'apibase';
    is $reservation->apikey, undef, 'no apikey';
    is $reservation->apisecret, undef, 'no apisecret';
    is $reservation->host, 'http://localhost', 'host';
};

subtest 'Reserve and Release Worker via CLI' => sub {
    my ($stdout, $stderr, @result) = capture sub { $cli->run('reservation', @auth_op, 2, '--duration=1h') };
    is_deeply \@result, [1],
      'A reservation attempt without comment fails with a non-zero exit code because comments are required';
    like $stdout, qr/comment/, 'The error details on stdout describe the missing comment requirement';
    like $stderr, qr/400 Bad Request/, 'The HTTP response on stderr is a 400 Bad Request';

    ($stdout, $stderr, @result)
      = capture sub { $cli->run('reservation', @auth_op, 2, '--comment=Testing', '--duration=1h') };
    is_deeply \@result, [0], 'A valid reservation with a comment and a duration succeeds with exit code 0';
    like $stdout, qr/reserved successfully/, 'The response on stdout confirms the worker is reserved successfully';

    ($stdout, $stderr, @result)
      = capture sub { $cli->run('reservation', @auth_op, 2, '--comment=Double', '--duration=1h') };
    is_deeply \@result, [1],
      'A double reservation attempt on an already reserved worker fails with a non-zero exit code';
    like $stdout, qr/already reserved/, 'The error details on stdout describe the reservation conflict';
    like $stderr, qr/409 Conflict/, 'The HTTP response on stderr is a 409 Conflict';

    ($stdout, $stderr, @result) = capture sub { $cli->run('reservation', @auth_op, 2, '--release') };
    is_deeply \@result, [0], 'Releasing the active reservation by the same operator succeeds with exit code 0';
    like $stdout, qr/released successfully/, 'The response on stdout confirms the reservation is released successfully';

    ($stdout, $stderr, @result)
      = capture
      sub { $cli->run('reservation', @auth_op, 2, '--comment=Testing', '--duration=1h', '--class=invalid tag') };
    is_deeply \@result, [1], 'A reservation attempt with an invalid tag fails with a non-zero exit code';
    like $stdout, qr/Invalid specific worker class/, 'The error details on stdout describe the invalid tag';

    ($stdout, $stderr, @result)
      = capture sub { $cli->run('reservation', @auth_op, 2, '--comment=Testing', '--duration=1h', '-C', 'poo123') };
    is_deeply \@result, [0], 'A valid reservation with a valid class tag succeeds';
    like $stdout, qr/"worker_class":\s*"poo123"/, 'The response JSON contains the expected worker_class';

    ($stdout, $stderr, @result) = capture sub { $cli->run('reservation', @auth_op, 2, '--release') };
};

subtest 'Reserve and Release Host via CLI' => sub {
    my $workers = $app->schema->resultset('Workers');
    my $w1 = $workers->create({host => 'cli-host', instance => 1});
    my $w2 = $workers->create({host => 'cli-host', instance => 2});

    throws_ok { $reservation->run() }
    qr/Usage: openqa-cli reservation/,
      'Command usage error is thrown when neither WORKER_ID nor --worker-host is supplied';

    throws_ok { $reservation->run(2, '--worker-host=cli-host') }
    qr/Usage: openqa-cli reservation/,
      'Command usage error is thrown when both WORKER_ID and --worker-host are supplied';

    my ($stdout, $stderr, @result) = capture sub {
        $cli->run('reservation', @auth_op, '--worker-host=cli-host', '--comment=maint', '--duration=1h', '-C',
            'poo167749');
    };
    is_deeply \@result, [0], 'Complete host reservation via CLI succeeds with exit code 0';
    like $stdout, qr/reserved successfully/, 'CLI stdout response confirms success';
    like $stdout, qr/"instances":/, 'CLI stdout response contains the list of reserved instances';

    $w1->discard_changes;
    ok $w1->is_reserved, 'Worker instance is successfully marked as reserved in the database';
    is $w1->reservation->{worker_class}, 'poo167749', 'Worker class tag is correctly set in database';

    ($stdout, $stderr, @result) = capture sub {
        $cli->run('reservation', @auth_op, '--worker-host=cli-host', '--release');
    };
    is_deeply \@result, [0], 'Complete host release via CLI succeeds with exit code 0';
    like $stdout, qr/released successfully/, 'CLI stdout response confirms host release';

    $w1->discard_changes;
    ok !$w1->is_reserved, 'Worker instance reservation is successfully removed from the database';

    $w1->delete;
    $w2->delete;
};

done_testing;
