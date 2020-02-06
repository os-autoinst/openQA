# Copyright (C) 2020 SUSE Software Solutions Germany GmbH
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

use File::Temp qw(tempfile);
use Mojo::File qw(path curfile);
use OpenQA::Test::Database;
use OpenQA::Test::Utils;
use Test::More;
use Test::Output;
use Test::Warnings;

sub run_once {
    my ($args) = @_;
    my $script = path(curfile->dirname, '../script/load_templates')->realpath;
    system("$script $args") >> 8;
}

my $ret;
my $args = '';
combined_like(sub { $ret = run_once($args) }, qr/Usage:/, 'help text shown');
is $ret, 1, 'load_templates with no arguments shows usage';

$args = "--host";
combined_like(sub { $ret = run_once($args) }, qr/Option host requires an argument/, 'host argument error shown');

my $host     = 'testhost:1234';
my $filename = 't/data/40-templates.pl';
$args = "--host $host $filename";
combined_like sub { $ret = run_once($args); }, qr/unknown error code - host $host unreachable?/, 'invalid host error';
is $ret, 22, 'error because host is invalid';

$ENV{MOJO_LOG_LEVEL} = 'fatal';
my $mojoport = Mojo::IOLoop::Server->generate_port;
$host = "localhost:$mojoport";
my $pid = OpenQA::Test::Utils::create_webapi($mojoport, sub { OpenQA::Test::Database->new->create; });
# Note: See t/fixtures/03-users.pl for test user credentials
my $apikey    = 'PERCIVALKEY02';
my $apisecret = 'PERCIVALSECRET02';
$args = "--host $host --apikey $apikey --apisecret $apisecret $filename";
combined_like sub { $ret = run_once($args); }, qr/Administrator level required/, 'Operator is not allowed';
is $ret, 255, 'error because of insufficient permissions';

$apikey    = 'ARTHURKEY01';
$apisecret = 'EXCALIBUR';
$args      = "--host $host --apikey $apikey --apisecret $apisecret $filename";
combined_like sub { $ret = run_once($args); }, qr/Job group.+not found/, 'Invalid job group';
is $ret, 255, 'failed to load templates with invalid job group';
kill TERM => $pid;

sub schema_hook {
    my $schema     = OpenQA::Test::Database->new->create;
    my $job_groups = $schema->resultset('JobGroups');
    $job_groups->create({name => 'openSUSE Leap 42.3 Updates'});
}
$mojoport = Mojo::IOLoop::Server->generate_port;
$host     = "localhost:$mojoport";
$pid      = OpenQA::Test::Utils::create_webapi($mojoport, \&schema_hook);
$args     = "--host $host --apikey $apikey --apisecret $apisecret $filename";
stdout_like sub { $ret = run_once($args); }, qr/JobGroups.+=> \{ added => 1, of => 1 \}/, 'Admin may load templates';
is $ret, 0, 'successfully loaded templates';

$filename = 't/data/40-templates.json';
$args     = "--host $host --apikey $apikey --apisecret $apisecret $filename";
combined_like sub { $ret = run_once($args); }, qr/Bad Request: No template specified/,
  'YAML template is mandatory (JSON)';
is $ret, 255, 'failed to load templates without YAML (JSON)';
kill TERM => $pid;

done_testing;
