#!/usr/bin/env perl
# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Data::Dumper;
use OpenQA::Git;
use OpenQA::Utils;
use OpenQA::Task::Needle::Save;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use Mojo::File 'tempdir';
use Test::MockModule;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::Output qw(stdout_like stdout_unlike combined_like);

# allow catching log messages via stdout_like
delete $ENV{OPENQA_LOGFILE};

my $fixtures = '01-jobs.pl 03-users.pl 05-job_modules.pl 07-needles.pl';
my $schema = OpenQA::Test::Database->new->create(fixtures_glob => $fixtures);
my $first_user = $schema->resultset('Users')->first;
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'run (arbitrary) command' => sub {
    ok(run_cmd_with_log([qw(echo Hallo Welt)]), 'run simple command');
    stdout_like { is(run_cmd_with_log([qw(false)]), '') } qr/[WARN].*[ERROR]/i;

    my $res = run_cmd_with_log_return_error([qw(echo Hallo Welt)]);
    is $res->{return_code}, 0, 'correct zero exit code returned ($? >> 8)';
    ok $res->{status}, 'status ok';
    is $res->{stdout}, "Hallo Welt\n", 'cmd output returned';

    stdout_like { $res = run_cmd_with_log_return_error([qw(false)]) } qr/.*\[error\].*cmd returned [1-9][0-9]*/i;
    is $res->{return_code}, 1, 'correct non-zero exit code returned ($? >> 8)';
    ok !$res->{status}, 'status not ok (non-zero status returned)';

    stdout_unlike { $res = run_cmd_with_log_return_error([qw(falße)]) } qr/.*cmd returned [1-9][0-9]*/i;
    is $res->{return_code}, undef, 'no exit code returned if command cannot be executed';
    is $res->{stderr}, 'an internal error occurred', 'error message returned as stderr';
    ok !$res->{status}, 'status not ok if command cannot be executed';

    stdout_like { $res = run_cmd_with_log_return_error(['bash', '-c', 'kill -s KILL $$']) }
    qr/.*cmd died with signal 9\n.*/i;
    is $res->{return_code}, undef, 'no exit code returned if command dies with a signal';
    ok !$res->{status}, 'status not ok if command dies with a signal';
};

subtest 'invoke Git commands for real testing error handling' => sub {
    throws_ok { OpenQA::Git->new({app => $t->app, dir => 'foo/bar'})->commit } qr/no user specified/,
      'exception if user missing';

    my $empty_tmp_dir = tempdir;
    my $git = OpenQA::Git->new({app => $t->app, dir => $empty_tmp_dir, user => $first_user});
    my $res;

    subtest 'invoking Git command outside of a Git repo' => sub {
        stdout_like { $res = $git->commit({cmd => 'status', message => 'test'}) }
        qr/.*\[warn\].*fatal: Not a git repository/i, 'Git error logged';
        like $res, qr"^Unable to commit via Git \($empty_tmp_dir\): fatal: (N|n)ot a git repository \(or any",
          'Git error returned';
        combined_like {
            throws_ok { $git->check_sha('this-sha-does-not-exist') } qr/internal Git error/i,
            'check throws an exception'
        } qr/\[error\].*cmd returned [1-9][0-9]*/, 'Git error logged for check as well';
    };

    combined_like {
        $git->invoke_command($_) for ['init'], ['config', 'user.email', 'foo@bar'], ['config', 'user.name', 'Foo'];
    }
    qr/\[info\].*cmd returned 0\n/, 'initialized Git repo; successful command exit logged as info';

    subtest 'error handling when checking sha' => sub {
        stdout_like { ok !$git->check_sha('this-sha-does-not-exist'), 'return code 1 interpreted correctly' }
          qr/\[info\].*cmd returned 1\n/i,
          'no error logged if check returns false (despite Git returning 1)';
    };

    subtest 'error handling when checking whether working directory is clean' => sub {
        my $test_file = $empty_tmp_dir->child('foo')->touch;
        combined_like { $git->commit({add => ['foo'], message => 'test'}) } qr/commit.*foo.*cmd returned 0/is,
          'commit created';
        stdout_like { ok $git->is_workdir_clean, 'return code 0 interpreted correctly' }
        qr/\[info\].*cmd returned 0\n/i, 'no error (only info) logged if check returns true';
        $test_file->spew('test');
        stdout_like { ok !$git->is_workdir_clean, 'return code 1 interpreted correctly' }
          qr/\[info\].*cmd returned 1\n/i,
          'no error (only info) logged if check returns false (despite Git returning 1)';
    };
};

# setup mocking
my @executed_commands;
my %mock_return_value = (
    status => 1,
    stderr => undef,
    return_code => 0,
);

sub _run_cmd_mock ($cmd, %args) {
    push @executed_commands, $cmd;
    return \%mock_return_value;
}

subtest 'git commands with mocked run_cmd_with_log_return_error' => sub {
    # check default config
    my $utils_mock = Test::MockModule->new('OpenQA::Git');
    $utils_mock->redefine(run_cmd_with_log_return_error => \&_run_cmd_mock);
    my $git = OpenQA::Git->new(app => $t->app, dir => 'foo/bar', user => $first_user);
    is($git->app, $t->app, 'app is set');
    is($git->dir, 'foo/bar', 'dir is set');
    is($git->user, $first_user, 'user is set');
    ok(!$git->enabled, 'git is not enabled by default');
    my $git_config = $t->app->config->{'scm git'};
    is($git->config, $git_config, 'global git config is mirrored');
    is($git->config->{update_remote}, '', 'by default no remote configured');
    is($git->config->{update_branch}, '', 'by default no branch configured');

    # read-only getters
    $git->enabled(1);
    ok(!$git->enabled, 'enabled is read-only');
    $git->config({});
    is($git->config, $git_config, 'config is read-only');

    # test set_to_latest_master effectively being a no-op because no update remote and branch have been configured
    is($git->set_to_latest_master, undef, 'no error if no update remote and branch configured');
    is_deeply(\@executed_commands, [], 'no commands executed if no update remote and branch configured')
      or always_explain \@executed_commands;

    # configure update branch and remote
    $git->config->{update_remote} = 'origin';
    $git->config->{update_branch} = 'origin/master';
    $git->config->{do_cleanup} = 'yes';
    is($git_config->{update_remote}, $git->config->{update_remote}, 'global git config reflects all changes');

    # test set_to_latest_master (non-error case)
    is($git->set_to_latest_master, undef, 'no error');
    is_deeply(
        \@executed_commands,
        [
            [qw(git -C foo/bar remote update origin)], [qw(git -C foo/bar reset --hard HEAD)],
            [qw(git -C foo/bar rebase origin/master)],
        ],
        'git remote update and rebase executed',
    ) or always_explain \@executed_commands;

    # test set_to_latest_master (error case)
    @executed_commands = ();
    $mock_return_value{status} = 0;
    $mock_return_value{stderr} = 'mocked error';
    $mock_return_value{stdout} = '';
    combined_like {
        is $git->set_to_latest_master, 'Unable to fetch from origin master (foo/bar): mocked error',
          'an error occurred on remote update';
    }
    qr/Error: mocked error/, 'error logged';
    is_deeply \@executed_commands, [[qw(git -C foo/bar remote update origin)]], 'git reset not attempted'
      or always_explain \@executed_commands;

    # test commit
    @executed_commands = ();
    $mock_return_value{status} = 1;
    is(
        $git->dir('/repo/path')->commit(
            {
                message => 'add rm test',
                add => [qw(foo.png foo.json)],
                rm => [qw(bar.png bar.json)],
            }
        ),
        undef,
        'no error occured'
    );
    is_deeply(
        \@executed_commands,
        [
            [qw(git -C /repo/path add foo.png foo.json)],
            [qw(git -C /repo/path rm bar.png bar.json)],
            [
                qw(git -C /repo/path commit -q -m),
                'add rm test',
                '--author=openQA system user <noemail@open.qa>',
                qw(foo.png foo.json bar.png bar.json)
            ],
        ],
        'changes staged and committed',
    ) or always_explain \@executed_commands;

    $git->config->{do_push} = 'yes';

    local $mock_return_value{status} = 1;
    local $mock_return_value{stderr} = 'mocked push error';
    local $mock_return_value{stdout} = '';

    $utils_mock->redefine(
        run_cmd_with_log_return_error => sub ($cmd, %args) {
            push @executed_commands, $cmd;
            if ($cmd->[7] eq 'push') {
                $mock_return_value{status} = 0;
            }
            return \%mock_return_value;
        });
    combined_like {
        like $git->commit({message => 'failed push test'}), qr/Unable to push Git commit/, 'error handled during push';
    }
    qr/Error: mocked push error/, 'push error logged';
    $git->config->{do_push} = '';
};

subtest 'saving needle via Git' => sub {
    my $utils_mock = Test::MockModule->new('OpenQA::Git');
    $utils_mock->redefine(run_cmd_with_log_return_error => \&_run_cmd_mock);
    {
        package Test::FakeMinionJob;    # uncoverable statement
        sub finish { }
        sub fail {
            Test::Most::fail("Minion job shouldn't have failed.");    # uncoverable statement
            Test::Most::note(Data::Dumper::Dumper(\@_));    # uncoverable statement
        }
    }

    # configure use of Git
    $t->app->config->{global}->{scm} = 'git';
    my $empty_tmp_dir = tempdir();

    # trigger saving needles like Minion would do
    @executed_commands = ();
    OpenQA::Task::Needle::Save::_save_needle(
        $t->app,
        bless({} => 'Test::FakeMinionJob'),
        {
            job_id => 99926,
            user_id => 99903,
            needle_json => '{"area":[{"xpos":0,"ypos":0,"width":0,"height":0,"type":"match"}],"tags":["foo"]}',
            needlename => 'foo',
            needledir => $empty_tmp_dir,
            imagedir => 't/data/openqa/share/tests/archlinux/needles',
            imagename => 'test-rootneedle.png',
        });
    is_deeply(
        \@executed_commands,
        [
            [qw(git -C), $empty_tmp_dir, qw(remote update origin)],
            [qw(git -C), $empty_tmp_dir, qw(reset --hard HEAD)],
            [qw(git -C), $empty_tmp_dir, qw(rebase origin/master)],
            [qw(git -C), $empty_tmp_dir, qw(add), "foo.json", "foo.png"],
            [
                qw(git -C), $empty_tmp_dir,
                qw(commit -q -m),
                'foo for opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
                '--author=Percival <percival@example.com>',
                "foo.json", "foo.png"
            ],
        ],
        'commands executed as expected'
    ) or always_explain \@executed_commands;

    # note: Saving needles is already tested in t/ui/12-needle-edit.t. However, Git is disabled in that UI test so
    #       it is tested here explicitly.
};

done_testing();
