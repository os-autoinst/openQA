#!/usr/bin/env perl -w

# Copyright (c) 2015 SUSE LINUX, Nuernberg, Germany.
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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use OpenQA::Utils;
use File::Copy;
use OpenQA::Test::Database;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

OpenQA::Test::Database->new->create();

my $t = Test::Mojo->new('OpenQA');

my $file = 't/data/7da661d0c3faf37d49d33b6fc308f2.png';
copy("t/images/34/.thumbs/7da661d0c3faf37d49d33b6fc308f2.png", $file);
is((stat($file))[7], 287, 'original file size');
$t->app->gru->enqueue(optipng => $file);

my $c = OpenQA::Plugin::Gru::Command::gru->new();
$c->app($t->app);
open(FD, ">", \my $output);
select FD;
$c->run('list');
close(FD);
select STDOUT;
like($output, qr,optipng .*'$file';,, 'optipng queued');

$c->run('run', '-o');
is((stat($file))[7], 286, 'optimized file size');

# now to something completely different
$t->app->gru->enqueue('limit_assets');
$c->run('run', '-o');

done_testing();
