#!/usr/bin/env perl -w

# Copyright (C) 2015-2016 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use OpenQA::Utils;
use OpenQA::Test::Case;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::Output qw/stderr_like/;

my $schema = OpenQA::Test::Case->new->init_data;

ok(run_cmd_with_log([qw/echo Hallo Welt/]), 'run simple command');

stderr_like {
    is(run_cmd_with_log([qw/false/]), '');
}
qr/[WARN].*[ERROR]/i;    # error printed on stderr

my $res = run_cmd_with_log_return_error([qw/echo Hallo Welt/]);
ok($res->{status}, 'status ok');
is($res->{stderr}, 'Hallo Welt', 'cmd output returned');

$res = run_cmd_with_log_return_error([qw/false/]);
ok(!$res->{status}, 'status not ok (non-zero status returned)');

$res = commit_git_return_error {
    dir     => '/some/dir',
    cmd     => 'status',
    message => 'test',
    user    => $schema->resultset('Users')->first
};
is($res, 'Unable to commit via Git: fatal: Not a git repository: \'/some/dir/.git\'', 'Git error message returned');

done_testing();
