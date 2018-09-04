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
# https://github.com/rurban/Cpanel-JSON-XS/issues/65
use JSON::PP;
use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Case;
use Mojo::File 'tempdir';
use Test::More;
use Test::Mojo;
use Test::Warnings;
use Test::Output qw(stderr_like);

my $schema = OpenQA::Test::Case->new->init_data;

ok(run_cmd_with_log([qw(echo Hallo Welt)]), 'run simple command');

stderr_like {
    is(run_cmd_with_log([qw(false)]), '');
}
qr/[WARN].*[ERROR]/i;    # error printed on stderr

my $res = run_cmd_with_log_return_error([qw(echo Hallo Welt)]);
ok($res->{status}, 'status ok');
is($res->{stderr}, 'Hallo Welt', 'cmd output returned');

stderr_like {
    $res = run_cmd_with_log_return_error([qw(false)]);
}
qr/.*\[ERROR\] cmd returned non-zero value/i;
ok(!$res->{status}, 'status not ok (non-zero status returned)');

my $empty_tmp_dir = tempdir();
stderr_like {
    $res = commit_git_return_error {
        dir     => $empty_tmp_dir,
        cmd     => 'status',
        message => 'test',
        user    => $schema->resultset('Users')->first
    };
}
qr/fatal: Not a git repository.*\n.*cmd returned non-zero value/i;
like(
    $res,
    qr'^Unable to commit via Git: fatal: (N|n)ot a git repository \(or any of the parent directories\): \.git$',
    'Git error message returned'
);

done_testing();
