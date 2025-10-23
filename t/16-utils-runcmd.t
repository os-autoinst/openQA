#!/usr/bin/env perl
# Copyright 2015-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Data::Dumper;
use OpenQA::Git;
use OpenQA::Task::Needle::Save;
use OpenQA::Task::SignalGuard;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';
use OpenQA::Utils;
use Mojo::File 'tempdir';
use Test::MockModule;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use Test::Output qw(stdout_like stdout_unlike combined_like);

# allow catching log messages via stdout_like
delete $ENV{OPENQA_LOGFILE};
# Avoid using tester's ~/.gitconfig
delete $ENV{HOME};

my $fixtures = '01-jobs.pl 03-users.pl 05-job_modules.pl 07-needles.pl';
my $schema = OpenQA::Test::Database->new->create(fixtures_glob => $fixtures);
my $first_user = $schema->resultset('Users')->first;
my $t = Test::Mojo->new('OpenQA::WebAPI');

my $empty_tmp_dir = tempdir();
my $fake_needle = {
    job_id => 99926,
    user_id => 99903,
    needle_json => '{"area":[{"xpos":0,"ypos":0,"width":0,"height":0,"type":"match"}],"tags":["foo"]}',
    needlename => 'foo',
    needledir => $empty_tmp_dir,
    imagedir => 't/data/openqa/share/tests/archlinux/needles',
    imagename => 'test-rootneedle.png',
};

subtest 'run (arbitrary) command' => sub {
    ok(run_cmd_with_log([qw(echo Hallo Welt)]), 'run simple command');
    stdout_like { is(run_cmd_with_log([qw(false)]), '') } qr/[WARN].*[ERROR]/i;

    my $res = run_cmd_with_log_return_error([qw(echo Hallo Welt)]);
    is $res->{return_code}, 0, 'correct zero exit code returned ($? >> 8)';
    ok $res->{status}, 'status ok';
    is $res->{stdout}, "Hallo Welt\n", 'cmd output returned';

    stdout_like { $res = run_cmd_with_log_return_error([qw(false)]) } qr/.*\[error\].*false returned [1-9][0-9]*/i;
    is $res->{return_code}, 1, 'correct non-zero exit code returned ($? >> 8)';
    ok !$res->{status}, 'status not ok (non-zero status returned)';

    stdout_unlike { $res = run_cmd_with_log_return_error([qw(falße)]) } qr/.*falße returned [1-9][0-9]*/i;
    is $res->{return_code}, undef, 'no exit code returned if command cannot be executed';
    is $res->{stderr}, 'an internal error occurred', 'error message returned as stderr';
    ok !$res->{status}, 'status not ok if command cannot be executed';

    stdout_like { $res = run_cmd_with_log_return_error(['bash', '-c', 'kill -s KILL $$']) }
    qr/.*bash died with signal 9\n.*/i;
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
        } qr/\[error\].*git returned [1-9][0-9]*/, 'Git error logged for check as well';
    };

    combined_like {
        $git->invoke_command($_) for ['init'], ['config', 'user.email', 'foo@bar'], ['config', 'user.name', 'Foo'];
    }
    qr/\[info\].*git returned 0\n/, 'initialized Git repo; successful command exit logged as info';

    subtest 'error handling when checking sha' => sub {
        stdout_like { ok !$git->check_sha('this-sha-does-not-exist'), 'return code 1 interpreted correctly' }
          qr/\[info\].*git returned 1\n/i,
          'no error logged if check returns false (despite Git returning 1)';
    };

    subtest 'error handling when checking whether working directory is clean' => sub {
        my $test_file = $empty_tmp_dir->child('foo')->touch;
        combined_like { $git->commit({add => ['foo'], message => 'test'}) } qr/commit.*foo.*git returned 0/is,
          'commit created';
        stdout_like { ok $git->is_workdir_clean, 'return code 0 interpreted correctly' }
        qr/\[info\].*git returned 0\n/i, 'no error (only info) logged if check returns true';
        $test_file->spew('test');
        stdout_like { ok !$git->is_workdir_clean, 'return code 1 interpreted correctly' }
          qr/\[info\].*git returned 1\n/i,
          'no error (only info) logged if check returns false (despite Git returning 1)';
    };

    subtest 'cache_ref' => sub {
        my $test_file = $empty_tmp_dir->child('foo')->touch;
        my $test_file_2 = "$empty_tmp_dir/bar";
        is $git->cache_ref('HEAD', undef, 'foo', $test_file),
          undef, 'return undef if output file already exists and could be touched';
        is $git->cache_ref('HEAD', undef, 'foo', $test_file_2), undef, 'checkout file with ref';
        ok -f $test_file_2, 'checkout succeeded';

        # and now with remote other than origin
        my $git_remote_dir = tempdir;
        note qx{rmdir "$git_remote_dir"};
        note qx{cp -a "$empty_tmp_dir/" "$git_remote_dir"};
        note qx{rm "$empty_tmp_dir/.git" -rf};
        note qx{git -C "$empty_tmp_dir" init -q};
        my $test_file_3 = "$empty_tmp_dir/baz";
        my $ref = qx{git -C "$git_remote_dir" rev-parse HEAD};
        chomp $ref;
        is($git->cache_ref($ref, "file://$git_remote_dir/.git", 'foo', $test_file_3),
            undef, 'checkout file from remote origin with ref');
        ok -f $test_file_3, 'checkout succeeded';

        my $test_file_4 = "$empty_tmp_dir/barinus";
        like(
            $git->cache_ref($ref, "file://$git_remote_dir/.git", 'bar', $test_file_4),
            qr"Unable to cache Git ref .* 'bar' exists on disk, but not in",
            'checking out non existing file fails'
        );
        ok !-f $test_file_4, 'task failed successfuly';
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
    ok(!$git->autocommit_enabled, 'git autocommit is not enabled by default');
    my $git_config = $t->app->config->{'scm git'};
    is($git->config, $git_config, 'global git config is mirrored');
    is($git->config->{update_remote}, '', 'by default no remote configured');
    is($git->config->{update_branch}, '', 'by default no branch configured');

    # read-only getters
    $git->autocommit_enabled(1);
    ok(!$git->autocommit_enabled, 'autocommit_enabled is read-only');
    $git->config({});
    is($git->config, $git_config, 'config is read-only');

    # enable git auto-commit a few different ways and check it
    $git->config->{git_auto_commit} = 'yes';
    ok($git->autocommit_enabled, 'git_auto_commit = yes enables autocommit');
    $git->config->{git_auto_commit} = '';
    ok(!$git->autocommit_enabled, 'git_auto_commit empty disables autocommit');
    $t->app->config->{global}->{scm} = 'git';
    ok($git->autocommit_enabled, 'git_auto_commit empty and scm = git enables autocommit');
    $git->config->{git_auto_commit} = 'no';
    ok(!$git->autocommit_enabled, 'git_auto_commit = no disables autocommit even with scm = git');

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

    package Test::FakeMinionJob {
        sub finish { }

        sub fail {
            Test::Most::fail('Minion job should not have failed.');    # uncoverable statement
            Test::Most::note(Data::Dumper::Dumper(\@_));    # uncoverable statement
        }
    }    # uncoverable statement

    # enable git auto-commit
    $t->app->config->{'scm git'}->{git_auto_commit} = 'yes';

    # trigger saving needles like Minion would do
    @executed_commands = ();
    OpenQA::Task::Needle::Save::_save_needle($t->app, bless({} => 'Test::FakeMinionJob'), $fake_needle);
    is_deeply(
        \@executed_commands,
        [
            [qw(git -C), "$empty_tmp_dir", qw(remote update origin)],
            [qw(git -C), "$empty_tmp_dir", qw(reset --hard HEAD)],
            [qw(git -C), "$empty_tmp_dir", qw(rebase origin/master)],
            [qw(git -C), "$empty_tmp_dir", qw(add), 'foo.json', 'foo.png'],
            [
                qw(git -C), "$empty_tmp_dir",
                qw(commit -q -m),
                'foo for opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
                '--author=Percival <percival@example.com>',
                'foo.json', 'foo.png'
            ],
        ],
        'commands executed as expected'
    ) or always_explain \@executed_commands;

    # note: Saving needles is already tested in t/ui/12-needle-edit.t. However, Git is disabled in that UI test so
    #       it is tested here explicitly.
};

subtest 'signal guard aborts when git is disabled and do_cleanup is "no"' => sub {

    package My::FakeSignalGuard {
        use Mojo::Base -base, -signatures;
        has 'abort' => sub { 0 };
    }    # uncoverable statement
    my $signal_guard;
    my $signal_guard_mock = Test::MockModule->new('OpenQA::Task::SignalGuard');
    $signal_guard_mock->redefine(new => sub { $signal_guard = My::FakeSignalGuard->new() });

    $t->app->config->{'scm git'}->{git_auto_commit} = 'no';    # disable autocommit
    $t->app->config->{'scm git'}->{do_cleanup} = 'no';    # disable cleanup

    # trigger saving needles like Minion would do
    @executed_commands = ();
    OpenQA::Task::Needle::Save::_save_needle($t->app, bless({} => 'Test::FakeMinionJob'), $fake_needle);

    isa_ok $signal_guard, 'My::FakeSignalGuard', 'signal guard has been created with the right class';
    ok $signal_guard->abort, 'signal guard is set to abort';
};

subtest 'save_needle returns and logs error when set_to_latest_master fails' => sub {

    package Test::FailingMinionJob {
        sub finish { }
        sub fail ($self, $args) { $self->{fail_message} = $args }
    }    # uncoverable statement

    sub _run_save_needle_test ($git_mock) {
        my @log_errors;
        my $log_mock = Test::MockModule->new(ref $t->app->log);
        $log_mock->redefine(error => sub ($self, $message) { push @log_errors, $message; });
        my $job = bless({} => 'Test::FailingMinionJob');
        OpenQA::Task::Needle::Save::_save_needle($t->app, $job, $fake_needle);

        like $log_errors[0], qr/Unable to fetch.*mocked/, 'error logged on fail';
        like $job->{fail_message}->{error},
          qr{<strong>Failed to save.*</strong>.*<pre>Unable to fetch.*mocked.*</pre>},
          'error message in fail';
    }

    my $git_mock = Test::MockModule->new('OpenQA::Git');
    $t->app->config->{'scm git'}->{git_auto_commit} = 'yes';    # enable autocommit
    $git_mock->redefine(set_to_latest_master => 'Unable to fetch from origin master: mocked error');

    subtest 'fails when git_auto_commit and do_cleanup are enabled ' => sub {
        $t->app->config->{'scm git'}->{do_cleanup} = 'yes';
        _run_save_needle_test($git_mock);
    };

    subtest 'fails when git_auto_commit is enabled and do_cleanup is disabled ' => sub {
        $t->app->config->{'scm git'}->{do_cleanup} = 'no';
        _run_save_needle_test($git_mock);
    };
};

done_testing();
