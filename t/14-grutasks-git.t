#!/usr/bin/env perl
# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Task::Git::Clone;
use OpenQA::Git::ServerAvailability qw(report_server_unavailable report_server_available SKIP FAIL);
require OpenQA::Test::Database;
use OpenQA::Test::Utils qw(run_gru_job perform_minion_jobs);
use OpenQA::Test::TimeLimit '20';
use Test::Output qw(combined_like stderr_like);
use Test::MockModule;
use Test::Mojo;
use Test::Warnings qw(:report_warnings);
use Mojo::Util qw(dumper scope_guard);
use Mojo::File qw(path tempdir);
use Time::Seconds;
use File::Copy::Recursive qw(dircopy);

# Avoid using tester's ~/.gitconfig
delete $ENV{HOME};

# Avoid tampering with git checkout
my $workdir = tempdir("$FindBin::Script-XXXX", TMPDIR => 1);
my $guard = scope_guard sub { chdir $FindBin::Bin };
chdir $workdir;
path('t/data/openqa/db')->make_path;
my $git_clones = "$workdir/git-clones";
mkdir $git_clones;
path("$git_clones/$_")->make_path
  for
  qw(default branch dirty-error dirty-status nodefault wrong-url sha1 sha2 sha-error sha-branchname opensuse opensuse/needles);
mkdir 't';
dircopy "$FindBin::Bin/$_", "$workdir/t/$_" or BAIL_OUT($!) for qw(data);

my $schema = OpenQA::Test::Database->new->create();
my $gru_tasks = $schema->resultset('GruTasks');
my $gru_dependencies = $schema->resultset('GruDependencies');
my $jobs = $schema->resultset('Jobs');
my $t = Test::Mojo->new('OpenQA::WebAPI');

# launch an additional app to serve some file for testing blocking downloads
my $mojo_port = Mojo::IOLoop::Server->generate_port;
my $webapi = OpenQA::Test::Utils::create_webapi($mojo_port, sub { });

# prevent writing to a log file to enable use of combined_like in the following tests
$t->app->log(Mojo::Log->new(level => 'info'));

# ensure git is enabled
$t->app->config->{global}->{scm} = 'git';

subtest 'git clone' => sub {
    my $openqa_git = Test::MockModule->new('OpenQA::Git');
    my @mocked_git_calls;
    my $clone_dirs = {
        "$git_clones/default/" => 'http://localhost/foo.git',
        "$git_clones/branch/" => 'http://localhost/foo.git#foobranch',
        "$git_clones/this_directory_does_not_exist/" => 'http://localhost/bar.git',
        "$git_clones/sha1" => 'http://localhost/present.git#abc',
        "$git_clones/sha2" => 'http://localhost/not-present.git#def',
        "$git_clones/sha-branchname" => 'http://localhost/present.git#a123',
    };
    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            push @mocked_git_calls, join(' ', map { tr/ // ? "'$_'" : $_ } @$cmd) =~ s/\Q$git_clones//r;
            my $stdout = '';
            splice @$cmd, 0, 4 if $cmd->[0] eq 'env';
            my $path = '';
            (undef, $path) = splice @$cmd, 1, 2 if $cmd->[1] eq '-C';
            my $action = $cmd->[1];
            my $return_code = 0;
            if ($action eq 'remote') {
                if ($clone_dirs->{$path}) {
                    $stdout = $clone_dirs->{$path} =~ s/#.*//r;
                }
                elsif ($path =~ m/opensuse/) {
                    $stdout = 'http://osado';
                }
                elsif ($path =~ m/wrong-url/) {
                    $stdout = 'http://other';
                }
            }
            elsif ($action eq 'ls-remote') {
                $stdout = 'ref: refs/heads/master	HEAD';
                $stdout = 'ref: something' if "@$cmd" =~ m/nodefault/;
            }
            elsif ($action eq 'branch') {
                $stdout = 'master';
            }
            elsif ($action eq 'diff-index') {
                $return_code = 1 if $path =~ m/dirty-status/;
                $return_code = 2 if $path =~ m/dirty-error/;
            }
            elsif ($action eq 'rev-parse') {
                if ($path =~ m/sha1/) {
                    $return_code = 0;
                    $stdout = 'abcdef123456';
                }
                if ($path =~ m/sha-branchname/) {
                    $return_code = 0;
                    $stdout = 'abcdef123456789';
                }
                $return_code = 1 if $path =~ m/sha2/;
                $return_code = 2 if $path =~ m/sha-error/;
            }
            return {
                status => $return_code == 0,
                return_code => $return_code,
                stderr => '',
                stdout => $stdout,
            };
        });
    my @gru_args = ($t->app, 'git_clone', $clone_dirs, {priority => 10});
    my $res;
    stderr_like { $res = run_gru_job(@gru_args) } qr{Git command failed.*verify};

    is $res->{result}, 'Job successfully executed', 'minion job result indicates success';
    #<<< no perltidy
    my $expected_calls = [
        # /sha1
        ['get-url'        => 'git -C /sha1 remote get-url origin'],
        ['rev-parse'      => 'git -C /sha1 rev-parse --verify -q abc'],

        # /sha2
        ['get-url'        => 'git -C /sha2 remote get-url origin'],
        ['rev-parse'      => 'git -C /sha2 rev-parse --verify -q def'],
        ['check dirty'    => 'git -C /sha2 diff-index HEAD --exit-code'],
        ['current branch' => 'git -C /sha2 branch --show-current'],
        ['fetch branch'   => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git -C /sha2 fetch origin def"],

        # /branch
        ['get-url'        => 'git -C /branch/ remote get-url origin'],
        ['check dirty'    => 'git -C /branch/ diff-index HEAD --exit-code'],
        ['current branch' => 'git -C /branch/ branch --show-current'],
        ['fetch branch'   => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git -C /branch/ fetch origin foobranch"],

        # /default/
        ['get-url'        => 'git -C /default/ remote get-url origin'],
        ['check dirty'    => 'git -C /default/ diff-index HEAD --exit-code'],
        ['default remote' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git ls-remote --symref http://localhost/foo.git HEAD"],
        ['current branch' => 'git -C /default/ branch --show-current'],
        ['fetch default'  => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git -C /default/ fetch origin master"],
        ['reset'          => 'git -C /default/ reset --hard origin/master'],

        # /sha-branchname
        ['get-url'        => 'git -C /sha-branchname remote get-url origin'],
        ['rev-parse'      => 'git -C /sha-branchname rev-parse --verify -q a123'],
        ['check dirty'    => 'git -C /sha-branchname diff-index HEAD --exit-code'],
        ['current branch' => 'git -C /sha-branchname branch --show-current'],
        ['fetch branch'   => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git -C /sha-branchname fetch origin a123"],

        # /this_directory_does_not_exist/
        ['clone' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git clone http://localhost/bar.git /this_directory_does_not_exist/"],
    ];
    #>>> no perltidy
    for my $i (0 .. $#$expected_calls) {
        my $test = $expected_calls->[$i];
        is $mocked_git_calls[$i], $test->[1], "$i: " . $test->[0];
    }

    subtest 'no default remote branch' => sub {
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 0;
        %$clone_dirs = ("$git_clones/nodefault" => 'http://localhost/nodefault.git');
        stderr_like { $res = run_gru_job(@gru_args) }
        qr(Error detecting remote default), 'error on stderr';
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/Error detecting remote default.*ref: something/, 'error message';
    };

    subtest 'git clone retried on failure' => sub {
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 1;
        my $openqa_clone = Test::MockModule->new('OpenQA::Task::Git::Clone');
        $openqa_clone->redefine(_git_clone => sub (@) { die "fake error\n" });
        $res = run_gru_job(@gru_args);
        is $res->{retries}, 1, 'job retries incremented';
        is $res->{state}, 'inactive', 'job set back to inactive';
    };
    subtest 'git clone fails when all retry attempts exhausted' => sub {
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 0;
        my $openqa_clone = Test::MockModule->new('OpenQA::Task::Git::Clone');
        $openqa_clone->redefine(_git_clone => sub (@) { die "fake error\n" });
        stderr_like { $res = run_gru_job(@gru_args) }
        qr(fake error), 'error message on stderr';
        is $res->{retries}, 0, 'job retries not incremented';
        is $res->{state}, 'failed', 'job considered failed';
    };

    subtest 'dirty git checkout' => sub {
        %$clone_dirs = ("$git_clones/dirty-status" => 'http://localhost/foo.git');
        stderr_like { $res = run_gru_job(@gru_args) }
        qr(git diff-index HEAD), 'error about diff on stderr';
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/NOT updating dirty Git checkout.*can disable.*details/s, 'error message';
    };

    subtest 'error testing dirty git checkout' => sub {
        %$clone_dirs = ("$git_clones/dirty-error/" => 'http://localhost/foo.git');
        stderr_like { $res = run_gru_job(@gru_args) }
        qr(Unexpected exit code 2), 'error message on stderr';
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/Internal Git error: Unexpected exit code 2/, 'error message';
    };

    subtest 'error testing local sha' => sub {
        %$clone_dirs = ("$git_clones/sha-error/" => 'http://localhost/foo.git#abc');
        stderr_like { $res = run_gru_job(@gru_args) }
        qr(Unexpected exit code 2), 'error message on stderr';
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/Internal Git error: Unexpected exit code 2/, 'error message';
    };

    subtest 'error because of different url' => sub {
        %$clone_dirs = ();
        my $clone_dirs2 = {"$git_clones/wrong-url/" => 'http://localhost/different.git'};
        stderr_like {
            $res = run_gru_job($t->app, 'git_clone', $clone_dirs2, {priority => 10})
        }
        qr(Local checkout.*has origin.*but requesting to clone from), 'Warning about different url';
        is $res->{state}, 'finished', 'minion job finished';
        is $res->{result}, 'Job successfully executed', 'minion job result indicates success';
    };

    subtest 'update clones without CASEDIR' => sub {
        @mocked_git_calls = ();
        #<<< no perltidy
        my $expected_calls = [
            # /opensuse
            ['get-url'        => 'git -C /opensuse remote get-url origin'],
            ['check dirty'    => 'git -C /opensuse diff-index HEAD --exit-code'],
            ['default remote' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git ls-remote --symref http://osado HEAD"],
            ['current branch' => 'git -C /opensuse branch --show-current'],
            ['fetch default ' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git -C /opensuse fetch origin master"],
            ['reset'          => 'git -C /opensuse reset --hard origin/master'],

            # /opensuse/needles
            ['get-url'        => 'git -C /opensuse/needles remote get-url origin'],
            ['check dirty'    => 'git -C /opensuse/needles diff-index HEAD --exit-code'],
            ['default remote' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git ls-remote --symref http://osado HEAD"],
            ['current branch' => 'git -C /opensuse/needles branch --show-current'],
            ['fetch branch'   => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' GIT_ASKPASS= GIT_TERMINAL_PROMPT=false git -C /opensuse/needles fetch origin master"],
            ['reset'          => 'git -C /opensuse/needles reset --hard origin/master'],
        ];
        #>>> no perltidy
        $ENV{OPENQA_GIT_CLONE_RETRIES} = 0;
        %$clone_dirs = (
            "$git_clones/opensuse" => undef,
            "$git_clones/opensuse/needles" => undef,
        );
        my $res = run_gru_job(@gru_args);
        is $res->{state}, 'finished', 'minion job finished';
        is $res->{result}, 'Job successfully executed', 'minion job result indicates success';
        for my $i (0 .. $#$expected_calls) {
            my $test = $expected_calls->[$i];
            is $mocked_git_calls[$i], $test->[1], "$i: " . $test->[0];
        }
    };

    subtest 'minion guard' => sub {
        my $guard = $t->app->minion->guard("git_clone_${git_clones}/opensuse_task", ONE_HOUR);
        my $start = time;
        $res = run_gru_job(@gru_args);
        is $res->{state}, 'inactive', 'job is inactive';
        ok(($res->{delayed} - $start) > 30, 'job delayed as expected');
    };
};

subtest 'git_update_all' => sub {
    my $clone_mock = Test::MockModule->new('OpenQA::Task::Git::Clone');
    $clone_mock->redefine(_git_clone => sub (@args) { die 'fake disconnect' });
    my $openqa_git = Test::MockModule->new('OpenQA::Git');
    $openqa_git->redefine(get_origin_url => 'foo');

    my $testdir = $workdir->child('openqa/share/tests');
    $testdir->make_path;
    my @clones;
    for my $path (qw(archlinux archlinux/products/archlinux/needles example opensuse opensuse/needles)) {
        push @clones, $testdir->child($path)->make_path . '';
        $testdir->child("$path/.git")->make_path;
    }
    local $ENV{OPENQA_BASEDIR} = $workdir;
    local $ENV{OPENQA_GIT_CLONE_RETRIES} = 4;
    local $ENV{OPENQA_GIT_CLONE_RETRIES_BEST_EFFORT} = 2;

    # disable git, first
    $t->app->config->{global}->{scm} = '';
    my $git_config = $t->app->config->{'scm git'};
    $git_config->{git_auto_update} = 'no';
    # test that this never disables update_all, it shouldn't
    $git_config->{git_auto_clone} = 'no';

    my $result = $t->app->gru->enqueue_git_update_all;
    is $result, undef, 'gru task not created yet';

    # now enable git but leave auto_update disabled
    $t->app->config->{global}->{scm} = 'git';
    $result = $t->app->gru->enqueue_git_update_all;
    is $result, undef, 'gru task not created yet';

    # now enable auto_update but disable git
    $t->app->config->{global}->{scm} = '';
    $git_config->{git_auto_update} = 'yes';
    $result = $t->app->gru->enqueue_git_update_all;
    is $result, undef, 'gru task not created yet';

    # now enable both, but leave auto_clone disabled, it should not
    # interfere
    $t->app->config->{global}->{scm} = 'git';
    $result = $t->app->gru->enqueue_git_update_all;
    my $minion = $t->app->minion;
    my $job = $minion->job($result->{minion_id});
    my $args = $job->info->{args}->[0];
    my $gru_id = $result->{gru_id};
    my $gru_task = $gru_tasks->find($gru_id);
    is_deeply [sort keys %$args], \@clones, 'job args as expected';
    isnt $gru_task, undef, 'gru task created';

    subtest 'error handling and retry behavior' => sub {
        # assume an openQA job is blocked on the Gru task
        my $blocked_job = $jobs->create({TEST => 'blocked-job'});
        $gru_task->jobs->create({job_id => $blocked_job->id});

        # perform job, it'll fail via the mocked _git_clone function
        $minion->foreground($job->id);    # already counts as retry
        is $job->info->{state}, 'inactive', 'job failed but set to inactive to be retried';
        is $gru_task->jobs->count, 1, 'openQA job not unblocked after first try';

        # retry the job now
        $minion->foreground($job->id);
        is $job->info->{state}, 'inactive', 'job failed but again set to inactive to be retried';
        is $gru_task->jobs->count, 0, 'openQA job unblocked after second try';

        combined_like { $minion->foreground($job->id) } qr/fake disconnect/, 'error logged';
        is $job->info->{state}, 'failed', 'job failed for real after retries exhausted';

        subtest 'method "strict"' => sub {
            local $ENV{OPENQA_GIT_CLONE_RETRIES_BEST_EFFORT} = 1;
            $git_config->{git_auto_update_method} = 'strict';
            $result = $t->app->gru->enqueue_git_update_all;
            $job = $minion->job($result->{minion_id});
            $gru_task = $gru_tasks->find($result->{gru_id});
            $gru_task->jobs->create({job_id => $blocked_job->id});
            $minion->foreground($job->id);
            is $job->info->{state}, 'inactive', 'job failed but again set to inactive to be retried';
            is $gru_task->jobs->count, 1, 'openQA job not unblocked with method "strict"';
        };
      }
      if $gru_task;
};

subtest 'enqueue_git_clones' => sub {
    my $minion = $t->app->minion;
    my $clones = {x => 'y'};
    my @j = map { $schema->resultset('Jobs')->create({state => 'scheduled', TEST => "t$_"}); } 1 .. 5;
    my $jobs = [$j[0]->id, $j[1]->id];

    # disable git, first
    $t->app->config->{global}->{scm} = '';

    my $result = $t->app->gru->enqueue_git_clones($clones, $jobs);
    is $result, undef, 'gru task not created yet';

    # now enable it
    $t->app->config->{global}->{scm} = 'git';
    $result = $t->app->gru->enqueue_git_clones($clones, $jobs);

    my $minion_job = $minion->job($result->{minion_id});
    my $job_id = $minion_job->id;
    my $task = $schema->resultset('GruTasks')->find($result->{gru_id});
    my @deps = $task->jobs;
    is_deeply [map $_->job_id, @deps], $jobs, 'expected GruDependencies created';

    subtest 'add to existing GruTask' => sub {
        my $enq = 0;
        my $mocked_gru = Test::MockModule->new('OpenQA::Shared::Plugin::Gru');
        $mocked_gru->redefine(enqueue => sub (@) { $enq++; });
        my $jobs = [$j[2]->id];
        my $result = $t->app->gru->enqueue_git_clones($clones, $jobs);
        my @deps = $task->jobs;
        is scalar @deps, 3, 'job was added to GruTask';
        is $deps[2]->job_id, $j[2]->id, 'third job was added to existing GruTask';
        is $enq, 0, 'enqueue was not called';
    };

    subtest 'skip GruTask for finished minion job' => sub {
        my $dbh = $schema->storage->dbh;
        my $sql = q{UPDATE minion_jobs set state = 'finished' WHERE id = ?};
        my $sth = $dbh->prepare($sql);
        $sth->execute($job_id);
        my $enq = 0;
        my $mocked_gru = Test::MockModule->new('OpenQA::Shared::Plugin::Gru');
        $mocked_gru->redefine(enqueue => sub (@) { $enq++; });
        my $jobs = [$j[3]->id];
        my $result = $t->app->gru->enqueue_git_clones($clones, $jobs);
        my @deps = $task->jobs;
        is scalar @deps, 3, 'no job was added to GruTask';
        is $enq, 0, 'enqueue was not called';
    };

    subtest 'skip GruTask because task done during assigning' => sub {
        $t->app->log(Mojo::Log->new(level => 'debug'));
        my $jobs = [$j[4]->id];
        stderr_like { $t->app->gru->_add_jobs_to_gru_task(999, $jobs) }
qr{GruTask 999 already gone.*insert or update on table "gru_dependencies" violates foreign key constraint "gru_dependencies_fk_gru_task_id"},
          'expected log output if GruTask deleted in between';
        my @deps = $task->jobs;
        is scalar @deps, 3, 'no job was added to GruTask';
    };
};

$t->app->log(Mojo::Log->new(level => 'info'));

subtest 'delete_needles' => sub {
    # disable git to start with, as the ad hoc distris we create are
    # not yet git repos, so if it's enabled the delete_needles task
    # fails
    $t->app->config->{global}->{scm} = '';
    my $needledirs = $schema->resultset('NeedleDirs');
    my $needles = $schema->resultset('Needles');
    $needledirs->create({id => 1, path => 't/data/openqa/share/tests/archlinux/needles', 'name' => 'test'});
    $needledirs->create({id => 2, path => 't/data/openqa/share/tests/fedora/needles', 'name' => 'test'});
    $needles->create({dir_id => 1, filename => 'test-rootneedle.json'});
    $needles->create({dir_id => 2, filename => 'test-duplicate-needle.json'});
    $needles->create({dir_id => 2, filename => 'test-rootneedle.json'});
    $needles->create({dir_id => 2, filename => 'test-nestedneedle-1.json'});
    $needles->create({dir_id => 2, filename => 'test-nestedneedle-2.json'});

    my %args = (needle_ids => [1, 2], user_id => 1);
    my @gru_args = ($t->app, 'delete_needles', \%args, {priority => 10});
    my $res = run_gru_job(@gru_args);
    is $res->{state}, 'finished', 'finished';
    is $#{$res->{result}->{errors}}, -1, 'no errors';
    is_deeply $res->{result}->{removed_ids}, [1, 2], 'removed expected ids';

    unlink 't/data/openqa/share/tests/fedora/needles/test-rootneedle.png';
    $args{needle_ids} = [3];
    $res = run_gru_job(@gru_args);
    my $error = $res->{result}->{errors}->[0];
    is $error->{display_name}, 'test-rootneedle.json', 'expected error for missing png';

    $args{needle_ids} = [99];
    $res = run_gru_job(@gru_args);
    $error = $res->{result}->{errors}->[0];
    like $error->{message}, qr{Unable to find needle.*99}, 'expected error for not existing needle';

    # now enable git
    $t->app->config->{global}->{scm} = 'git';
    $t->app->config->{git_auto_commit} = 'yes';
    $t->app->config->{'scm git'}->{do_push} = 'yes';
    my $openqa_git = Test::MockModule->new('OpenQA::Git');
    my @cmds;
    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            push @cmds, "@$cmd";
            if (grep m/push/, @$cmd) {
                return {
                    status => 0,
                    return_code => 128,
                    stderr => q{fatal: Authentication failed for 'https://github.com/lala},
                    stdout => ''
                };
            }
            return {status => 1};
        });
    $args{needle_ids} = [4];
    stderr_like { $res = run_gru_job(@gru_args) } qr{Git command failed: .*push}, 'Got error on stderr';
    is $res->{state}, 'finished', 'git job finished';
    like $res->{result}->{errors}->[0]->{message},
      qr{Unable to push Git commit. See .*_setting_up_git_support on how to setup}, 'Got error for push';

    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            push @cmds, "@$cmd";
            return {status => 1};
        });
    $res = run_gru_job(@gru_args);
    is $res->{state}, 'finished', 'git job finished';
    like $cmds[0], qr{git.*rm.*test-nestedneedle-1.json}, 'git rm was executed';
    like $cmds[1], qr{git.*commit.*Remove.*test-nestedneedle-1.json}, 'git commit was executed';
    like $cmds[2], qr{git.*push}, 'git push was executed';

    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            push @cmds, "@$cmd";
            return {status => 0, stderr => 'lala', stdout => ''};
        });
    $args{needle_ids} = [5];
    stderr_like { $res = run_gru_job(@gru_args) } qr{Git command failed.*git.*rm}, 'expected stderr';
    is $res->{state}, 'finished', 'git job finished';
    $error = $res->{result}->{errors}->[0];
    like $error->{message}, qr{Unable to rm via Git}, 'expected error from git';

    subtest 'minion guard' => sub {
        my $guard = $t->app->minion->guard('git_clone_t/data/openqa/share/tests/fedora/needles_task', ONE_HOUR);
        $res = run_gru_job(@gru_args);
        is $res->{state}, 'finished', 'job finished';
        $error = $res->{result}->{errors}->[0];
        like $error->{message}, qr{Another git task for.*fedora.*is ongoing}, 'expected error message';
    };
};

subtest ServerAvailability => sub {
    my $tmpdir = tempdir();
    local $ENV{OPENQA_GIT_SERVER_OUTAGE_FILE} = "$tmpdir/foo/mock";

    subtest 'no flag file => skip' => sub {
        my $outcome = report_server_unavailable($t->app, 'gitlab');
        is $outcome, 'SKIP', 'Skips when flag file for gitlab is absent';
    };

    subtest 'file present but younger than 1800 => skip' => sub {
        my $mock_file = $tmpdir->child('foo/mock.gitlab.flag')->touch;
        my $outcome = report_server_unavailable($t->app, 'gitlab');
        is $outcome, 'SKIP', 'Skips the job for an mtime < 1800';
    };

    subtest 'file present and older => fail' => sub {
        my $mock_file = $tmpdir->child('foo/mock.gitlab.flag')->touch;
        my $old_time = time - 2000;
        utime($old_time, $old_time, $mock_file)
          or die "Couldn't change mtime on file: $mock_file - $!";
        my $outcome = report_server_unavailable($t->app, 'gitlab');
        is $outcome, 'FAIL', 'Fails the job when mtime >= 1800';
    };

    subtest 'report_server_available removes existing flag file' => sub {
        my $mock_file = $tmpdir->child('foo/mock.gitlab.flag')->touch;
        ok -f $mock_file, 'mock.gitlab.flag exists initially';
        report_server_available($t->app, 'gitlab');
        ok !-f $mock_file, 'gitlab flag file was removed';
    };

    subtest 'multiple servers do not conflict' => sub {
        my $outcome_gitlab = report_server_unavailable($t->app, 'gitlab');
        is $outcome_gitlab, 'SKIP', 'No gitlab flag => skip';
        my $gitlab_file = "$tmpdir/foo/mock.gitlab.flag";
        ok -f $gitlab_file, 'Created mock.gitlab.flag';
        my $outcome_github = report_server_unavailable($t->app, 'github');
        is $outcome_github, 'SKIP', 'No github flag => skip';
        my $github_file = "$tmpdir/foo/mock.github.flag";
        ok -f $github_file, 'Created mock.github.flag';

        my $old_time = time - 2000;
        utime($old_time, $old_time, $github_file);
        # Re-check
        $outcome_gitlab = report_server_unavailable($t->app, 'gitlab');
        $outcome_github = report_server_unavailable($t->app, 'github');
        is $outcome_gitlab, 'SKIP', 'GitLab file still fresh => skip';
        is $outcome_github, 'FAIL', 'GitHub file older => fail';
    };

    subtest Clone => sub {
        my $clone_mock = Test::MockModule->new('OpenQA::Task::Git::Clone');
        $clone_mock->redefine(_git_clone => sub { die "Internal API unreachable\n" });
        subtest 'Internal API unreachable => skip' => sub {
            my @gru_args = (
                $t->app,
                'git_clone',
                {
                    '/my/mock/path' => 'git@gitlab.suse.de:qa/foo',
                });
            my $res;
            combined_like {
                $res = run_gru_job(@gru_args);
            }
            qr/Git server outage likely, skipping clone job/i,
              'Minion clone job skipped due to short Git server outage';
            is $res->{state}, 'finished', 'Job ended in "finished" state';
            is $res->{result}, 'Job successfully executed', 'Job result indicates success (skip)';
        };

        subtest 'Internal API unreachable => fail' => sub {
            $tmpdir->child('foo/mock.gitlab.suse.de.flag')->touch;
            my $old_time = time - 2000;    # "older" than 1800s
            utime($old_time, $old_time, "$tmpdir/foo/mock.gitlab.suse.de.flag");
            my @gru_args = (
                $t->app,
                'git_clone',
                {
                    '/my/other/mock/path' => 'https://gitlab.suse.de/qa/foo',
                });
            my $res;
            combined_like {
                $res = run_gru_job(@gru_args);
            }
            qr/Prolonged Git server outage, failing the job/i,
              'Minion clone job failed due to prolonged Git server outage';
            is $res->{state}, 'failed', 'Job ended in "failed" state';
            like $res->{result}, qr/Internal API unreachable/, 'Job result includes original error message';
        };
    };
};

done_testing();

# clear gru task queue at end of execution so no 'dangling' tasks
# break subsequent tests; can happen if a subtest creates a task but
# does not execute it, or we crash partway through a subtest...
END {
    $webapi and $webapi->signal('TERM');
    $webapi and $webapi->finish;
    $t && $t->app->minion->reset;
}
