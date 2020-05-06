#!/usr/bin/env perl
# Copyright (C) 2015-2020 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib";
use Data::Dumper;
use OpenQA::Git;
use OpenQA::Utils;
use OpenQA::Task::Needle::Save;
use OpenQA::Test::Case;
use Mojo::File 'tempdir';
use Test::MockModule;
use Test::Mojo;
use Test::Warnings;
use Test::Output 'stdout_like';

# allow catching log messages via stdout_like
delete $ENV{OPENQA_LOGFILE};

my $schema     = OpenQA::Test::Database->new->create();
my $first_user = $schema->resultset('Users')->first;
my $t          = Test::Mojo->new('OpenQA::WebAPI');

subtest 'run (arbitrary) command' => sub {
    ok(run_cmd_with_log([qw(echo Hallo Welt)]), 'run simple command');
    stdout_like(
        sub {
            is(run_cmd_with_log([qw(false)]), '');
        },
        qr/[WARN].*[ERROR]/i
    );

    my $res = run_cmd_with_log_return_error([qw(echo Hallo Welt)]);
    ok($res->{status}, 'status ok');
    is($res->{stderr}, 'Hallo Welt', 'cmd output returned');

    stdout_like(
        sub {
            $res = run_cmd_with_log_return_error([qw(false)]);
        },
        qr/.*\[error\].*cmd returned [1-9][0-9]*/i
    );
    ok(!$res->{status}, 'status not ok (non-zero status returned)');
};

subtest 'make git commit (error handling)' => sub {
    throws_ok(
        sub {
            OpenQA::Git->new({app => $t->app, dir => 'foo/bar'})->commit();
        },
        qr/no user specified/,
        'OpenQA::Git thows an exception if parameter missing'
    );

    my $empty_tmp_dir = tempdir();
    my $res;
    stdout_like(
        sub {
            $res = OpenQA::Git->new(
                {
                    app  => $t->app,
                    dir  => $empty_tmp_dir,
                    user => $first_user,
                }
            )->commit(
                {
                    cmd     => 'status',
                    message => 'test',
                });
        },
        qr/.*\[warn\].*fatal: Not a git repository.*\n.*cmd returned [1-9][0-9]*/i
    );
    like(
        $res,
        qr'^Unable to commit via Git: fatal: (N|n)ot a git repository \(or any of the parent directories\): \.git$',
        'Git error message returned'
    );
};

# setup mocking
my @executed_commands;
my $utils_mock        = Test::MockModule->new('OpenQA::Git');
my %mock_return_value = (
    status => 1,
    stderr => undef,
);
$utils_mock->redefine(
    run_cmd_with_log_return_error => sub {
        my ($cmd) = @_;
        push(@executed_commands, $cmd);
        return \%mock_return_value;
    });

subtest 'git commands with mocked run_cmd_with_log_return_error' => sub {
    # check default config
    my $git = OpenQA::Git->new(app => $t->app, dir => 'foo/bar', user => $first_user);
    is($git->app,  $t->app,     'app is set');
    is($git->dir,  'foo/bar',   'dir is set');
    is($git->user, $first_user, 'user is set');
    ok(!$git->enabled, 'git is not enabled by default');
    my $git_config = $t->app->config->{'scm git'};
    is($git->config,                  $git_config, 'global git config is mirrored');
    is($git->config->{update_remote}, '',          'by default no remote configured');
    is($git->config->{update_branch}, '',          'by default no branch configured');

    # read-only getters
    $git->enabled(1);
    ok(!$git->enabled, 'enabled is read-only');
    $git->config({});
    is($git->config, $git_config, 'config is read-only');

    # test set_to_latest_master effectively being a no-op because no update remote and branch have been configured
    is($git->set_to_latest_master, undef, 'no error if no update remote and branch configured');
    is_deeply(\@executed_commands, [], 'no commands executed if no update remote and branch configured')
      or diag explain \@executed_commands;

    # configure update branch and remote
    $git->config->{update_remote} = 'origin';
    $git->config->{update_branch} = 'origin/master';
    is($git_config->{update_remote}, $git->config->{update_remote}, 'global git config reflects all changes');

    # test set_to_latest_master (non-error case)
    is($git->set_to_latest_master, undef, 'no error');
    is_deeply(
        \@executed_commands,
        [[qw(git -C foo/bar remote update origin)], [qw(git -C foo/bar rebase origin/master)],],
        'git remote update and rebase executed',
    ) or diag explain \@executed_commands;

    # test set_to_latest_master (error case)
    @executed_commands         = ();
    $mock_return_value{status} = 0;
    $mock_return_value{stderr} = 'mocked error';
    is(
        $git->set_to_latest_master,
        'Unable to fetch from origin master: mocked error',
        'an error occured on remote update'
    );
    is_deeply(\@executed_commands, [[qw(git -C foo/bar remote update origin)],], 'git reset not attempted',)
      or diag explain \@executed_commands;

    # test commit
    @executed_commands = ();
    $mock_return_value{status} = 1;
    is(
        $git->dir('/repo/path')->commit(
            {
                message => 'some test',
                add     => [qw(foo.png foo.json)],
                rm      => [qw(bar.png bar.json)],
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
                'some test',
                '--author=openQA system user <noemail@open.qa>',
                qw(foo.png foo.json bar.png bar.json)
            ],
        ],
        'changes staged and committed',
    ) or diag explain \@executed_commands;
};

subtest 'saving needle via Git' => sub {
    {
        package Test::FakeMinionJob;
        sub finish {
        }
        sub fail {
            Test::Most::fail("Minion job shouldn't have failed.");
            Test::Most::note(Data::Dumper::Dumper(\@_));
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
            job_id      => 99926,
            user_id     => 99903,
            needle_json => '{"area":[{"xpos":0,"ypos":0,"width":0,"height":0,"type":"match"}],"tags":["foo"]}',
            needlename  => 'foo',
            needledir   => $empty_tmp_dir,
            imagedir    => 't/data/openqa/share/tests/archlinux/needles',
            imagename   => 'test-rootneedle.png',
        });
    is_deeply(
        \@executed_commands,
        [
            [qw(git -C), $empty_tmp_dir, qw(remote update origin)],
            [qw(git -C), $empty_tmp_dir, qw(rebase origin/master)],
            [qw(git -C), $empty_tmp_dir, qw(add), "$empty_tmp_dir/foo.json", "$empty_tmp_dir/foo.png"],
            [
                qw(git -C),
                $empty_tmp_dir,
                qw(commit -q -m),
                'foo for opensuse-Factory-staging_e-x86_64-Build87.5011-minimalx@32bit',
                '--author=Percival <percival@example.com>',
                "$empty_tmp_dir/foo.json",
                "$empty_tmp_dir/foo.png"
            ],
        ],
        'commands executed as expected'
    ) or diag explain \@executed_commands;

    # note: Saving needles is already tested in t/ui/12-needle-edit.t. However, Git is disabled in that UI test so
    #       it is tested here explicitely.
};

done_testing();
