BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

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

use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

my $t = Test::Mojo->new('OpenQA');

my $cfg = $t->app->config;

is(length($cfg->{_openid_secret}), 16, "config has openid_secret");
delete $cfg->{_openid_secret};

is_deeply($cfg,{
		needles_git_do_push  => "no",
		needles_git_worktree => "/var/lib/os-autoinst/needles",
		needles_scm          => "git",
	}, 'default config');

$ENV{OPENQA_CONFIG} = 't/testcfg.ini';
open(my $fd, '>', $ENV{OPENQA_CONFIG});
print $fd "allowed_hosts=foo bar\n";
print $fd "suse_mirror=http://blah/\n";
close $fd;

$t = Test::Mojo->new('OpenQA');
ok($t->app->config->{'allowed_hosts'} eq 'foo bar', 'allowed hosts');
ok($t->app->config->{'suse_mirror'} eq 'http://blah/', 'suse mirror');

unlink($ENV{OPENQA_CONFIG});

done_testing();
