#!/usr/bin/env perl -w

# Copyright (C) 2015-2019 SUSE LLC
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use strict;
use warnings;

BEGIN {
    unshift @INC, 'lib';
}

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Case;
use Mojo::File 'tempdir';
use Test::More;
use Test::MockModule;
use Test::Mojo;
use Test::Warnings;
use Test::Output qw(stderr_like);

# allow catching log messages via stdout_like
delete $ENV{OPENQA_LOGFILE};

my $schema     = OpenQA::Test::Database->new->create();
my $first_user = $schema->resultset('Users')->first;

subtest 'run (arbitrary) command' => sub {
    ok(run_cmd_with_log([qw(echo Hallo Welt)]), 'run simple command');
    stderr_like(
        sub {
            is(run_cmd_with_log([qw(false)]), '');
        },
        qr/[WARN].*[ERROR]/i
    );

    my $res = run_cmd_with_log_return_error([qw(echo Hallo Welt)]);
    ok($res->{status}, 'status ok');
    is($res->{stderr}, 'Hallo Welt', 'cmd output returned');

    stderr_like(
        sub {
            $res = run_cmd_with_log_return_error([qw(false)]);
        },
        qr/.*\[error\].*cmd returned [1-9][0-9]*/i
    );
    ok(!$res->{status}, 'status not ok (non-zero status returned)');
};

subtest 'make git commit (error handling)' => sub {
    my $empty_tmp_dir = tempdir();
    my $res;
    stderr_like(
        sub {
            $res = commit_git {
                dir     => $empty_tmp_dir,
                user    => $first_user,
                cmd     => 'status',
                message => 'test',
            };
        },
        qr/.*\[warn\].*fatal: Not a git repository.*\n.*cmd returned [1-9][0-9]*/i
    );
    like(
        $res,
        qr'^Unable to commit via Git: fatal: (N|n)ot a git repository \(or any of the parent directories\): \.git$',
        'Git error message returned'
    );
};

# setup a Mojo app after all because the git commands need it
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'git commands with mocked run_cmd_with_log_return_error' => sub {
    # setup mocking
    my @executed_commands;
    my $utils_mock        = Test::MockModule->new('OpenQA::Utils');
    my %mock_return_value = (
        status => 1,
        stderr => undef,
    );
    $utils_mock->mock(
        run_cmd_with_log_return_error => sub {
            my ($cmd) = @_;
            push(@executed_commands, $cmd);
            return \%mock_return_value;
        });

    # test set_to_latest_git_master (non-error case)
    is(set_to_latest_git_master({dir => 'foo/bar'}), undef, 'no error occured');
    is_deeply(
        \@executed_commands,
        [[qw(git -C foo/bar fetch origin master:master)], [qw(git -C foo/bar rebase origin/master)],],
        'git fetch and reset executed',
    ) or diag explain \@executed_commands;

    # test set_to_latest_git_master (error case)
    @executed_commands         = ();
    $mock_return_value{status} = 0;
    $mock_return_value{stderr} = 'mocked error';
    is(
        set_to_latest_git_master({dir => 'foo/bar'}),
        'Unable to fetch from origin master: mocked error',
        'an error occured on fetch'
    );
    is_deeply(\@executed_commands, [[qw(git -C foo/bar fetch origin master:master)],], 'git reset not attempted',)
      or diag explain \@executed_commands;

    # test commit_git
    @executed_commands = ();
    $mock_return_value{status} = 1;
    is(
        commit_git(
            {
                dir     => '/repo/path',
                user    => $first_user,
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

done_testing();
