# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use File::Temp qw(tempfile);
use Mojo::Base -signatures;
use Mojo::File qw(path curfile);
require OpenQA::Test::Database;
use OpenQA::Test::Utils;
use Test::Output;
use Test::Warnings ':report_warnings';
use Test::Mojo;
use OpenQA::Test::Client 'client';
use OpenQA::Test::TimeLimit '30';
use OpenQA::Test::Utils qw(run_cmd test_cmd stop_service);
use Mojo::JSON;    # booleans
use Cpanel::JSON::XS ();


sub test_once {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    test_cmd(path(curfile->dirname, '../script/openqa-load-templates')->realpath, @_);
}

sub dump_templates {
    # Report failure at the callsite instead of the test function
    local $Test::Builder::Level = $Test::Builder::Level + 1;
    test_cmd(path(curfile->dirname, '../script/openqa-dump-templates')->realpath, @_);
}

sub decode { Cpanel::JSON::XS->new->relaxed->decode(path(shift)->slurp); }

sub check_property ($schema, $table, $property, $values) {
    my @gotprops = sort map { $_->$property } $schema->resultset($table)->all;
    is_deeply(\@gotprops, $values, "$property entries in $table as expected") or always_explain \@gotprops;
}

test_once '--help', qr/Usage:/, 'help text shown', 0, 'openqa-load-templates with no arguments shows usage';
test_once '--host', qr/Option host requires an argument/, 'host argument error shown', 1, 'required arguments missing';

my $host = 'testhost:1234';
my $filename = 't/data/40-templates.pl';
my $morefilename = 't/data/40-templates-more.pl';
my $args = "--host $host $filename";
test_once $args, qr/unknown error code - host $host unreachable?/, 'invalid host error', 22, 'error on invalid host';

$ENV{MOJO_LOG_LEVEL} = 'fatal';
my $mojoport = Mojo::IOLoop::Server->generate_port;
$host = "localhost:$mojoport";
my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl 03-users.pl 04-products.pl');
my $webapi = OpenQA::Test::Utils::create_webapi($mojoport, sub { });
END { stop_service $webapi; }
# Note: See t/fixtures/03-users.pl for test user credentials
my $apikey = 'PERCIVALKEY02';
my $apisecret = 'PERCIVALSECRET02';
$args = "--host $host --apikey $apikey --apisecret $apisecret $filename";
test_once $args, qr/Administrator level required/, 'Operator not allowed', 255, 'error on insufficient permissions';

$apikey = 'ARTHURKEY01';
$apisecret = 'EXCALIBUR';
my $base_args = "--host $host --apikey $apikey --apisecret $apisecret";
$args = "$base_args $filename";
my $expected
  = qr/JobGroups +=> \{ added => 1, of => 1 \},\n +JobTemplates +=> \{ added => 0, of => 0 \},\n +Machines +=> \{ added => 1, of => 1 \},\n +Products +=> \{ added => 1, of => 1 \},\n +TestSuites +=> \{ added => 1, of => 1 \}/;
my $expectednochange
  = qr/JobGroups +=> \{ added => 0, of => 1 \},\n +JobTemplates +=> \{ added => 0, of => 0 \},\n +Machines +=> \{ added => 0, of => 1 \},\n +Products +=> \{ added => 0, of => 1 \},\n +TestSuites +=> \{ added => 0, of => 1 \}/;
test_once $args, $expected, 'Admin may load templates', 0, 'successfully loaded templates';
test_once $args, $expectednochange, 'Reload does not modify without --update', 0, 'succeeded without change';
$args = "$base_args --update $filename";
test_once $args, $expected, 'Reload with --update modifies', 0, 'updated template with existing job group';

subtest 'test changing existing entries' => sub {
    my $t = client(Test::Mojo->new(), apikey => $apikey, apisecret => $apisecret);

    # overwrite testsuite settings
    $t->get_ok("http://$host/api/v1/test_suites?name=uefi")->status_is(200);
    my $test_suite_id = $t->tx->res->json->{TestSuites}->[0]->{id};
    $t->put_ok("http://$host/api/v1/test_suites/$test_suite_id", json => {name => "uefi", settings => {UEFI => '42'}})
      ->status_is(200);

    # check overwriting testsuite settings
    $t->get_ok("http://$host/api/v1/test_suites/$test_suite_id")->status_is(200)
      ->json_is('/TestSuites/0/settings/0/value', '42');

    # change testsuite settings back by reimporting template
    $args = "$base_args --update $filename";
    test_once $args, $expected, 'Admin may load templates', 0, 'successfully loaded templates with update flag';

    # check overwriting testsuite settings
    $t->get_ok("http://$host/api/v1/test_suites/$test_suite_id")->status_is(200);
    is((grep { $_->{key} eq 'UEFI' } @{$t->tx->res->json->{TestSuites}->[0]->{settings}})[0]->{value},
        '1', 'value changed back during update');
};

# the test fixtures that we loaded contain:
# 3 machines '32bit', '64bit', 'Laptop_64'
# job group 1001 'opensuse' (legacy)
# job group 1002 'opensuse test' (legacy)
# 7 test suites textmode, kde, RAID0, client1, server,client2, advanced_kde
# 3 products, one with 10 job templates (all in 'opensuse' group), two with none
# 40-templates.pl which we loaded above contains:
# 1 machine '128bit'
# 1 test suite 'uefi' which occurs in no product / job template
# 1 job group 'openSUSE Leap 42.3 Updates' (modern, empty templates string)
# 1 product opensuse-42.2-DVD-x86_64
# 0 job templates

# the 'opensuse' legacy group is unrealistic, as it contains an
# advanced_kde job template with settings and a description. This is
# not possible to achieve via the API (only templates produced from
# a YAML job group can have settings/description). Test that we reject
# dumping such a group unless --convert is passed:
$expected = qr,Settings and/or description unexpectedly present.*group opensuse,;
dump_templates $base_args, $expected, 'dump_templates fails on legacy group with settings', 1,
  'dump_templates handles error';
$expected = qr/JobGroups\s*=> \[.*group_name\s*=> "opensuse"/s;
$args = "$base_args --convert";
dump_templates $args, $expected, 'dump_templates with --convert', 0, 'dump_templates success with --convert';
# Also test with --group, for full code coverage
$args = "$base_args --convert --group opensuse";
dump_templates $args, $expected, 'dump_templates with --convert --group', 0,
  'dump_templates success with --convert --group';

# now wipe the unrealistic settings and description, as following test
# will correctly fail if they are present
$schema->resultset('JobTemplateSettings')->delete;
$schema->resultset('JobTemplates')->update({description => ''});

my $fh;
my $tempfilename;
($fh, $tempfilename) = tempfile(UNLINK => 1, SUFFIX => '.json');
$args = "$base_args --json > $tempfilename";
$expected = qr/^$/;
dump_templates $args, $expected, 'dumped fixtures';
# Clear the data in relevant tables
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates JobGroups);
$args = "$base_args $tempfilename";
# we load the modern job group as a JobGroup
# legacy group 'opensuse' will be loaded implicitly via its JobTemplates
# legacy group 'opensuse test' disappears at this point as it has no templates
$expected
  = qr/JobGroups +=> \{ added => 1, of => 1 \},\n +JobTemplates +=> \{ added => 10, of => 10 \},\n +Machines +=> \{ added => 4, of => 4 \},\n +Products +=> \{ added => 4, of => 4 \},\n +TestSuites +=> \{ added => 8, of => 8 \}/;
test_once $args, $expected, 're-imported fixtures';
my ($rh, $reference) = tempfile(UNLINK => 1, SUFFIX => '.json');
$args = "$base_args --json > $reference";
$expected = qr/^$/;
dump_templates $args, $expected, 're-dumped fixtures';
eq_or_diff_text decode($tempfilename), decode($reference), 'both dumps match';
# check we have at least vaguely the stuff we intend to have
check_property($schema, 'Machines', 'name', ['128bit', '32bit', '64bit', 'Laptop_64']);
check_property($schema, 'JobGroups', 'name', ['openSUSE Leap 42.3 Updates', 'opensuse']);
check_property($schema, 'JobTemplates', 'prio', [40, 40, 40, 40, 40, 40, 40, 40, 40, 40]);
check_property($schema, 'Products', 'arch', ['i586', 'ppc64', 'x86_64', 'x86_64']);
check_property($schema, 'TestSuites', 'name',
    ['RAID0', 'advanced_kde', 'client1', 'client2', 'kde', 'server', 'textmode', 'uefi']);
my $modjg = $schema->resultset('JobGroups')->find({name => 'openSUSE Leap 42.3 Updates'});
ok $modjg->template, 'modern group template reloaded';
my $legjg = $schema->resultset('JobGroups')->find({name => 'opensuse'});
ok !$legjg->template, 'legacy group has no template';

subtest 'dump_templates tests' => sub {
    $args = $base_args;
    dump_templates "$args Products42", qr/Invalid table.*42/, 'Error on non-existant table', 1, 'table error';
    $args .= " --test uefi --machine 128bit --group opensuse --product bar --full JobTemplates";
    $expected = qr/JobTemplates\s*=> \[.*group_name\s*=> "opensuse"/s;
    dump_templates $args, $expected, 'dump_templates with options', 0, 'dump_templates success with options';
    # this test intends to hit job_templates_scheduling/openSUSE Leap 42
    # and find it doesn't exist; we need --convert to use that endpoint
    $args = "$base_args --convert --group \"openSUSE Leap 42\"";
    $expected = qr/ERROR requesting.*404 - Not Found/;
    dump_templates $args, $expected, 'dump_templates fails on wrong group', 1, 'dump_templates handles error';
};

# now dump with --convert and reload, which will convert 'opensuse' to a YAML group
$args = "$base_args --convert --json > $tempfilename";
$expected = qr/^$/;
dump_templates $args, $expected, 'dumped fixtures';
# clear data again
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates JobGroups);
$args = "$base_args $tempfilename";
$expected
  = qr/JobGroups +=> \{ added => 2, of => 2 \},\n +Machines +=> \{ added => 4, of => 4 \},\n +Products +=> \{ added => 4, of => 4 \},\n +TestSuites +=> \{ added => 8, of => 8 \}/;
test_once $args, $expected, 're-imported fixtures';
$legjg = $schema->resultset('JobGroups')->find({name => 'opensuse'});
ok $legjg->template, 'formerly-legacy group now has template';
# the right number of job templates showed up, with priorities
check_property($schema, 'JobTemplates', 'prio', [40, 40, 40, 40, 40, 40, 40, 40, 40, 40]);

# Clear the data in relevant tables again
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates JobGroups);
# load the templates file with 2 machines
$args = "--host $host --apikey $apikey --apisecret $apisecret $morefilename";
$expected = qr/Machines.+=> \{ added => 2, of => 2 \}/;
test_once $args, $expected, 'imported MOAR fixtures';
# now load the templates file with only 1 machine, with --clean
$args = "--host $host --apikey $apikey --apisecret $apisecret --clean $filename";
$expected = qr/Machines.+=> \{ added => 1, of => 1 \}/;
test_once $args, $expected, 'imported original fixtures';
is $schema->resultset('Machines')->count, 1, "only one machine is loaded";
my $machine = $schema->resultset('Machines')->first;
is $machine->name, "128bit", "correct machine is loaded";

# Clear the data in relevant tables again
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates JobGroups);
# load a template file with YAML job group settings and description
$args = "$base_args t/data/40-templates-jgs.pl";
$expected = qr/JobGroups +=> \{ added => 1, of => 1 \}/;
test_once $args, $expected, 'imported YAML job groups';
# check we got the expected job template with settings and description
my $found = 0;
for my $jt ($schema->resultset('JobTemplates')->all) {
    next unless $jt->test_suite->name eq 'advanced_kde';
    $found++;
    $expected = {DESKTOP => 'advanced_kde', ADVANCED => '1'};
    eq_or_diff $jt->settings_hash, $expected, 'advanced_kde job template has expected settings';
    is $jt->description, 'such advanced very test', 'job template has expected description';
}
is $found, 1, 'exactly one advanced_kde job template was found';

# now let's test --clean / --update with YAML groups
# clear the templates, but leave the job group in existence
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates);
$schema->resultset('JobGroups')->update({template => ''});
# test reload without --clean or --update does nothing as the group exists
$expected = qr/JobGroups +=> \{ added => 0, of => 1 \}/;
test_once $args, $expected, 're-import without --clean or --update does nothing';
# test with --update and 'empty' state
$args = "$base_args --update t/data/40-templates-jgs.pl";
$expected = qr/JobGroups +=> \{ added => 1, of => 1 \}/;
test_once $args, $expected, 're-import with --update works';
is $schema->resultset('JobTemplates')->count, 3, 'job templates were loaded';
# change template string and test we can --clean over it (in fact we
# always overwrite the string, clean and update are the same in this regard)
# TODO: make --clean empty existing templates for all job groups, even
# ones we're not writing to
$schema->resultset($_)->delete for qw(Machines TestSuites Products JobTemplates);
$schema->resultset('JobGroups')->update({template => "scenarios: {}\nproducts: {}\n"});
$args = "$base_args --clean t/data/40-templates-jgs.pl";
$expected = qr/JobGroups +=> \{ added => 1, of => 1 \}/;
test_once $args, $expected, 're-import with --update works';
is $schema->resultset('JobTemplates')->count, 3, 'job templates were loaded';

done_testing;
