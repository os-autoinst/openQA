BEGIN { unshift @INC, 'lib'; }

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
use OpenQA::Test::Database;

OpenQA::Test::Database->new->create(skip_fixtures => 1);

my $t = Test::Mojo->new('OpenQA::WebAPI');

my $cfg = $t->app->config;

is(length($cfg->{_openid_secret}), 16, "config has openid_secret");
delete $cfg->{_openid_secret};

is_deeply(
    $cfg,
    {
        global => {
            appname       => 'openQA',
            branding      => "openSUSE",
            hsts          => '365',
            audit_enabled => 1,
        },
        auth => {
            method => 'Fake',
        },
        'scm git' => {
            do_push => 'no',
        },
        logging => {
            level => 'debug',
        },
        openid => {
            provider  => 'https://www.opensuse.org/openid/user/',
            httpsonly => '1',
        },
        hypnotoad => {
            listen => ['http://localhost:9526/'],
            proxy  => 1,
        },
        audit => {
            blacklist => 'job_grab job_done',
        }});

$ENV{OPENQA_CONFIG} = 't';
open(my $fd, '>', $ENV{OPENQA_CONFIG} . '/openqa.ini');
print $fd "[global]\n";
print $fd "allowed_hosts=foo bar\n";
print $fd "suse_mirror=http://blah/\n";
close $fd;

$t = Test::Mojo->new('OpenQA::WebAPI');
ok($t->app->config->{'global'}->{'allowed_hosts'} eq 'foo bar',    'allowed hosts');
ok($t->app->config->{'global'}->{'suse_mirror'} eq 'http://blah/', 'suse mirror');

unlink($ENV{OPENQA_CONFIG} . '/openqa.ini');

done_testing();
