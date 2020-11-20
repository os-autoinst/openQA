# Copyright (C) 2020 SUSE LLC
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
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use File::Temp qw(tempfile);
use Mojo::File qw(path curfile);
use OpenQA::Test::Database;
use OpenQA::Test::Utils;
use Test::Output;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '20';
use OpenQA::Test::Utils qw(run_cmd test_cmd stop_service);
use Mojo::JSON;    # booleans
use Cpanel::JSON::XS ();


sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    test_cmd(path(curfile->dirname, '../script/load_templates')->realpath, @_);
}

sub dump_templates {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    test_cmd(path(curfile->dirname, '../script/dump_templates')->realpath, @_);
}

sub decode { Cpanel::JSON::XS->new->relaxed->decode(path(shift)->slurp); }

test_once '--help', qr/Usage:/, 'help text shown', 0, 'load_templates with no arguments shows usage';
test_once '--host', qr/Option host requires an argument/, 'host argument error shown', 1, 'required arguments missing';

my $host         = 'testhost:1234';
my $filename     = 't/data/40-templates.pl';
my $morefilename = 't/data/40-templates-more.pl';
my $args         = "--host $host $filename";
test_once $args, qr/unknown error code - host $host unreachable?/, 'invalid host error', 22, 'error on invalid host';

$ENV{MOJO_LOG_LEVEL} = 'fatal';
my $mojoport = Mojo::IOLoop::Server->generate_port;
$host = "localhost:$mojoport";
my $schema = OpenQA::Test::Database->new->create;
my $webapi = OpenQA::Test::Utils::create_webapi($mojoport, sub { });
END { stop_service $webapi; }
# Note: See t/fixtures/03-users.pl for test user credentials
my $apikey    = 'PERCIVALKEY02';
my $apisecret = 'PERCIVALSECRET02';
$args = "--host $host --apikey $apikey --apisecret $apisecret $filename";
test_once $args, qr/Administrator level required/, 'Operator not allowed', 255, 'error on insufficient permissions';

$apikey    = 'ARTHURKEY01';
$apisecret = 'EXCALIBUR';
$args      = "--host $host --apikey $apikey --apisecret $apisecret $filename";
my $expected = qr/JobGroups.+=> \{ added => 1, of => 1 \}/;
test_once $args, $expected, 'Admin may load templates', 0, 'successfully loaded templates';
test_once $args, qr/group with existing name/, 'Duplicate job group', 255, 'failed on duplicate job group';

my $fh;
my $tempfilename;
($fh, $tempfilename) = tempfile(UNLINK => 1, SUFFIX => '.json');
$args     = "--host $host --apikey $apikey --apisecret $apisecret --json > $tempfilename";
$expected = qr/^$/;
dump_templates $args, $expected, 'dumped fixtures';
# Clear the data in relevant tables
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates JobGroups);
$args     = "--host $host --apikey $apikey --apisecret $apisecret $tempfilename";
$expected = qr/JobGroups.+=> \{ added => 3, of => 3 \}/;
test_once $args, $expected, 're-imported fixtures';
my ($rh, $reference) = tempfile(UNLINK => 1, SUFFIX => '.json');
$args     = "--host $host --apikey $apikey --apisecret $apisecret --json > $reference";
$expected = qr/^$/;
dump_templates $args, $expected, 're-dumped fixtures';
is_deeply decode($tempfilename), decode($reference), 'both dumps match';

# Clear the data in relevant tables again
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates JobGroups);
# load the templates file with 2 machines
$args     = "--host $host --apikey $apikey --apisecret $apisecret $morefilename";
$expected = qr/Machines.+=> \{ added => 2, of => 2 \}/;
test_once $args, $expected, 'imported MOAR fixtures';
# wipe jobgroups manually as --clean explicitly skips it
$schema->resultset("JobGroups")->delete;
# now load the templates file with only 1 machine, with --clean
$args     = "--host $host --apikey $apikey --apisecret $apisecret --clean $filename";
$expected = qr/Machines.+=> \{ added => 1, of => 1 \}/;
test_once $args, $expected, 'imported original fixtures';
is $schema->resultset('Machines')->count, 1, "only one machine is loaded";
my $machine = $schema->resultset('Machines')->first;
is $machine->name, "32bit", "correct machine is loaded";

done_testing;
