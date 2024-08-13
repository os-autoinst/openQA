# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::MockObject;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA::Git;

my $mock = Test::MockModule->new('OpenQA::Utils');
$mock->redefine('run_cmd_with_log_return_error', sub {
    my ($cmd) = @_;

    if ($cmd->[1] eq 'push') {
        # Simulate a failure when attempting to push
        return { status => 0 };
    }
    # Simulate success for other git commands ('add', 'commit')
    return { status => 1 };
});

my $mock_app = Test::MockObject->new();
$mock_app->set_always('config', {
    'global' => { 'scm' => 'git' },
    'scm git' => { 'do_push' => 'yes' }
});

my $mock_user = Test::MockObject->new();
$mock_user->set_always('fullname', 'Test User');
$mock_user->set_always('email', 'test.user@example.com');

my $git = OpenQA::Git->new(app => $mock_app, dir => '.', user => $mock_user);

my $result = $git->commit({
    add => ['t/16-utils-git.t'],
    message => 'Test commit message',
});

is $result, 'Unable to push Git commit', 'Commit method correctly handles push failure';

done_testing;
