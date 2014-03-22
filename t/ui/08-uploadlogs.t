# Copyright (C) 2014 SUSE Linux Products GmbH
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
  unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data;

my $t = Test::Mojo->new('OpenQA');

$t->app->log->level('debug');

# no such job
my $req = $t->post_ok('/tests/99961/uploadlog/test.tar.gz', { } => form => {})->status_is(404);

$req = $t->post_ok('/tests/99937/uploadlog/test.tar.gz', { } => form => {})->status_is(400);
$req->content_is('test not running');

# no file actually uploaded
$req = $t->post_ok('/tests/99963/uploadlog/test.tar.gz', { } => form => {})->status_is(404);

# not in git
mkdir('t/data/openqa/testresults/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde');
my $file = Mojo::Asset::File->new->add_chunk('lalala');
$req = $t->post_ok('/tests/99963/uploadlog/test.tar.gz' => form => { upload => 
     { file => $file} })->status_is(200);
$req->content_like(qr{OK: .*data/openqa/testresults/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/ulogs/test.tar.gz\n});

open(TFILE, "t/data/openqa/testresults/00099963-opensuse-13.1-DVD-x86_64-Build0091-kde/ulogs/test.tar.gz");
my $content = <TFILE>;
close(TFILE);

is($content, 'lalala', 'uploaded correctly');

done_testing();
