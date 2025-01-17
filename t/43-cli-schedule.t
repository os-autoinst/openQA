# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(:report_warnings warning);
use Mojo::Base -strict, -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::Test::TimeLimit '7';
use OpenQA::CLI;
use OpenQA::CLI::monitor;
use OpenQA::CLI::schedule;
use OpenQA::Jobs::Constants;
use OpenQA::Test::Case;
use Mojo::Server::Daemon;
use Mojo::File qw(tempdir tempfile);
use Test::Output qw(combined_like);
use Test::MockModule;

$ENV{OPENQA_CLI_RETRIES} = 0;

my $schema = OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');
my $schedule = OpenQA::CLI::schedule->new;

# change API to simulate job state/result changes
my $job_controller_mock = Test::MockModule->new('OpenQA::WebAPI::Controller::API::V1::Job');
my @job_mock_results = (PASSED, SOFTFAILED, PASSED, USER_CANCELLED);    # results to assume for job 1, job 2, …
$job_controller_mock->redefine(
    get_status => sub ($self) {
        # reply as usual
        $job_controller_mock->original('get_status')->($self);
        # fake that the job is done which will affect the next status query
        my $job = $self->schema->resultset('Jobs')->find(int($self->stash('jobid')));
        $job->done(result => (shift(@job_mock_results) // PASSED), reason => 'mocked') if $job && $job->result eq NONE;
    });

# start web server
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app = $daemon->build_app('OpenQA::WebAPI');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";
$app->log->level($ENV{HARNESS_IS_VERBOSE} ? 'debug' : 'error');
$app->config->{'scm git'}->{git_auto_update} = 'no';

combined_like { OpenQA::CLI->new->run('help', 'schedule') } qr/Usage: openqa-cli schedule/, 'help';
subtest 'unknown options' => sub {
    like warning {
        eval { $schedule->run('--unknown') }
    }, qr/Unknown option: unknown/, 'right output';
    like $@, qr/Usage: openqa-cli schedule/, 'unknown option';
};

# define different sets of CLI args to be used in further tests
my @basic_options = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', '--host', $host, '-i', 0);
my @options = (@basic_options, '-m');
my @scenarios = ('--param-file', "SCENARIO_DEFINITIONS_YAML=$FindBin::Bin/data/09-schedule_from_file.yaml");
my @settings1 = (qw(DISTRI=example VERSION=0 FLAVOR=DVD ARCH=x86_64 TEST=simple_boot));
my @settings2 = (qw(DISTRI=opensuse VERSION=13.1 FLAVOR=DVD ARCH=i586 BUILD=0091 TEST=autoyast_btrfs));

subtest 'running into error reply' => sub {
    my $res;
    combined_like { $res = $schedule->run(@options) } qr/Error: missing parameters: DISTRI VERSION FLAVOR ARCH/,
      '"missing parameters" error';
    is $schedule->host, $host, 'host set';
    is $res, 1, 'non-zero return-code if parameters missing';

    combined_like { $res = $schedule->run(@options, @settings1) } qr/no products found for/,
      '"no products found" error';
    is $res, 1, 'non-zero return-code if no products could be found';
};

subtest 'scheduling and monitoring zero-sized set of jobs' => sub {
    my $res;
    combined_like { $res = $schedule->run(@options, @scenarios, @settings1) } qr/count.*0/, 'response logged';
    is $res, 0, 'zero return-code';
};

subtest 'scheduling and monitoring set of two jobs' => sub {
    my $res;
    combined_like { $res = $schedule->run(@options, @scenarios, @settings2) }
    qr|2 jobs have been created.*(http://127.0.0.1.*/tests/\d+.*){2}passed.*softfailed|s,
      'response logged if all jobs are ok';
    is $res, 0, 'zero return-code if all jobs are ok';

    combined_like { $res = $schedule->run(@options, @scenarios, @settings2) } qr/count.*2.*passed.*user_cancelled/s,
      'response logged if one job was cancelled';
    is $res, 2, 'non-zero return-code if at least one job is not ok';
};

subtest 'monitor jobs as a separate command' => sub {
    my $res;
    my $monitor = OpenQA::CLI::monitor->new;
    my $jobs = $schema->resultset('Jobs');
    $jobs->create({id => $_, TEST => "test-$_"}) for (100 .. 103);
    @job_mock_results = (PASSED, SOFTFAILED);
    combined_like { $res = $monitor->run(@basic_options, 100, 101) } qr/100.*101/s, 'status logged (passing case)';
    is $res, 0, 'zero return-code if all jobs ok';
    @job_mock_results = (PASSED, FAILED);
    combined_like { $res = $monitor->run(@basic_options, 102, 103) } qr/102.*103/s, 'status logged (failing case)';
    is $res, 2, 'none-zero return-code if one job failed';
    $jobs->create({id => 105, TEST => "test-105", result => PASSED, state => DONE});
    $jobs->create({id => 104, TEST => "test-104", clone_id => 105, result => INCOMPLETE, state => DONE});
    $job_controller_mock->unmock('get_status');
    combined_like { $res = $monitor->run(@basic_options, '-f', 104) } qr/105/s, 'followed job via clone';
    is $res, 0, 'zero return-code if clone of followed jobs ok';
};

done_testing();
