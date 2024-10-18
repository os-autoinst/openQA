#!/usr/bin/env perl
# Copyright 2016-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Task::Git::Clone;
require OpenQA::Test::Database;
use OpenQA::Test::Utils qw(run_gru_job perform_minion_jobs);
use OpenQA::Test::TimeLimit '20';
use Test::Output qw(stderr_like);
use Test::MockModule;
use Test::Mojo;
use Test::Warnings qw(:report_warnings);
use Mojo::Util qw(dumper scope_guard);
use Mojo::File qw(path tempdir);
use Time::Seconds;
use File::Copy::Recursive qw(dircopy);

# Avoid tampering with git checkout
my $workdir = tempdir("$FindBin::Script-XXXX", TMPDIR => 1);
my $guard = scope_guard sub { chdir $FindBin::Bin };
chdir $workdir;
path('t/data/openqa/db')->make_path;
my $git_clones = "$workdir/git-clones";
mkdir $git_clones;
mkdir "$git_clones/$_" for qw(default branch dirty-error dirty-status nodefault wrong-url sha1 sha2 sha-error);
mkdir 't';
dircopy "$FindBin::Bin/$_", "$workdir/t/$_" or BAIL_OUT($!) for qw(data);

my $schema = OpenQA::Test::Database->new->create();
my $t = Test::Mojo->new('OpenQA::WebAPI');

# launch an additional app to serve some file for testing blocking downloads
my $mojo_port = Mojo::IOLoop::Server->generate_port;
my $webapi = OpenQA::Test::Utils::create_webapi($mojo_port, sub { });

# prevent writing to a log file to enable use of combined_like in the following tests
$t->app->log(Mojo::Log->new(level => 'info'));

subtest 'git clone' => sub {
    my $openqa_git = Test::MockModule->new('OpenQA::Git');
    my @mocked_git_calls;
    my $clone_dirs = {
        "$git_clones/default/" => 'http://localhost/foo.git',
        "$git_clones/branch/" => 'http://localhost/foo.git#foobranch',
        "$git_clones/this_directory_does_not_exist/" => 'http://localhost/bar.git',
        "$git_clones/sha1" => 'http://localhost/present.git#abc',
        "$git_clones/sha2" => 'http://localhost/not-present.git#def',
    };
    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd) {
            push @mocked_git_calls, join(' ', map { tr/ // ? "'$_'" : $_ } @$cmd) =~ s/\Q$git_clones//r;
            my $stdout = '';
            splice @$cmd, 0, 2 if $cmd->[0] eq 'env';
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
                $return_code = 2
                  if $path =~ m/dirty-error/;
            }
            elsif ($action eq 'rev-parse') {
                $return_code = 0 if $path =~ m/sha1/;
                $return_code = 128 if $path =~ m/sha2/;
                $return_code = 1 if $path =~ m/sha-error/;
            }
            return {
                status => $return_code == 0,
                return_code => $return_code,
                stderr => '',
                stdout => $stdout,
            };
        });
    my @gru_args = ($t->app, 'git_clone', $clone_dirs, {priority => 10});
    my $res = run_gru_job(@gru_args);
    is $res->{result}, 'Job successfully executed', 'minion job result indicates success';
    #<<< no perltidy
    my $expected_calls = [
        # /sha1
        ['get-url'        => 'git -C /sha1 remote get-url origin'],
        ['get-url'        => 'git -C /sha1 rev-parse --verify -q abc'],

        # /sha2
        ['get-url'        => 'git -C /sha2 remote get-url origin'],
        ['get-url'        => 'git -C /sha2 rev-parse --verify -q def'],
        ['check dirty'    => 'git -C /sha2 diff-index HEAD --exit-code'],
        ['current branch' => 'git -C /sha2 branch --show-current'],
        ['fetch branch'   => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git -C /sha2 fetch origin def"],

        # /branch
        ['get-url'        => 'git -C /branch/ remote get-url origin'],
        ['check dirty'    => 'git -C /branch/ diff-index HEAD --exit-code'],
        ['current branch' => 'git -C /branch/ branch --show-current'],
        ['fetch branch'   => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git -C /branch/ fetch origin foobranch"],

        # /default/
        ['get-url'        => 'git -C /default/ remote get-url origin'],
        ['check dirty'    => 'git -C /default/ diff-index HEAD --exit-code'],
        ['default remote' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git ls-remote --symref http://localhost/foo.git HEAD"],
        ['current branch' => 'git -C /default/ branch --show-current'],
        ['fetch default'  => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git -C /default/ fetch origin master"],
        ['reset'          => 'git -C /default/ reset --hard origin/master'],

        # /this_directory_does_not_exist/
        ['clone' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git clone http://localhost/bar.git /this_directory_does_not_exist/"],
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
        like $res->{result}, qr/NOT updating dirty git checkout/, 'error message';
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
        qr(Unexpected exit code 1), 'error message on stderr';
        is $res->{state}, 'failed', 'minion job failed';
        like $res->{result}, qr/Internal Git error: Unexpected exit code 1/, 'error message';
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
            ['default remote' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git ls-remote --symref http://osado HEAD"],
            ['current branch' => 'git -C /opensuse branch --show-current'],
            ['fetch default ' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git -C /opensuse fetch origin master"],
            ['reset'          => 'git -C /opensuse reset --hard origin/master'],

            # /opensuse/needles
            ['get-url'        => 'git -C /opensuse/needles remote get-url origin'],
            ['check dirty'    => 'git -C /opensuse/needles diff-index HEAD --exit-code'],
            ['default remote' => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git ls-remote --symref http://osado HEAD"],
            ['current branch' => 'git -C /opensuse/needles branch --show-current'],
            ['fetch branch'   => "env 'GIT_SSH_COMMAND=ssh -oBatchMode=yes' git -C /opensuse/needles fetch origin master"],
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
    $t->app->config->{'scm git'}->{git_auto_update} = 'yes';
    my $testdir = $workdir->child('openqa/share/tests');
    $testdir->make_path;
    my @clones;
    for my $path (qw(archlinux archlinux/products/archlinux/needles example opensuse opensuse/needles)) {
        push @clones, $testdir->child($path)->make_path . '';
        $testdir->child("$path/.git")->make_path;
    }
    local $ENV{OPENQA_BASEDIR} = $workdir;
    my $minion = $t->app->minion;
    my $result = $t->app->gru->enqueue_git_update_all;
    my $job = $minion->job($result->{minion_id});
    my $args = $job->info->{args}->[0];
    is_deeply [sort keys %$args], \@clones, 'job args as expected';
};

subtest 'enqueue_git_clones' => sub {
    my $minion = $t->app->minion;
    my $clones = {x => 'y'};
    my @j = map { $schema->resultset('Jobs')->create({state => 'scheduled', TEST => "t$_"}); } 1 .. 5;
    my $jobs = [$j[0]->id, $j[1]->id];
    my $result = $t->app->gru->enqueue_git_clones($clones, $jobs);
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

    $t->app->config->{global}->{scm} = 'git';
    my $openqa_git = Test::MockModule->new('OpenQA::Git');
    my @cmds;
    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd) {
            push @cmds, "@$cmd";
            return {status => 1};
        });
    $args{needle_ids} = [4];
    $res = run_gru_job(@gru_args);
    is $res->{state}, 'finished', 'git job finished';
    like $cmds[0], qr{git.*rm.*test-nestedneedle-1.json}, 'git rm was executed';
    like $cmds[1], qr{git.*commit.*Remove.*test-nestedneedle-1.json}, 'git commit was executed';

    $openqa_git->redefine(
        run_cmd_with_log_return_error => sub ($cmd) {
            push @cmds, "@$cmd";
            return {status => 0, stderr => 'lala', stdout => ''};
        });
    $args{needle_ids} = [5];
    stderr_like { $res = run_gru_job(@gru_args) } qr{Git command failed.*git.*rm}, 'expected stderr';
    is $res->{state}, 'finished', 'git job finished';
    $error = $res->{result}->{errors}->[0];
    like $error->{message}, qr{Unable to rm via Git}, 'expected error from git';

    subtest 'minion guard' => sub {
        my $guard = $t->app->minion->guard("git_clone_t/data/openqa/share/tests/fedora/needles_task", ONE_HOUR);
        $res = run_gru_job(@gru_args);
        is $res->{state}, 'finished', 'job finished';
        $error = $res->{result}->{errors}->[0];
        like $error->{message}, qr{Another git task for.*fedora.*is ongoing}, 'expected error message';
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
