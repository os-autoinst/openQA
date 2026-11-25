#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Cpanel::JSON::XS ();
use IPC::Run qw(run timeout);
use Mojo::File qw(path tempdir);
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '30';

my $schema_name = OpenQA::Test::Database::generate_schema_name;
my $schema = OpenQA::Test::Database->new->create(schema_name => $schema_name);
my $groups = $schema->resultset('JobGroups');
my $parents = $schema->resultset('JobGroupParents');

my $parent_with_own_limits = $parents->create(
    {
        name => 'parent with own retention limits',
        default_keep_logs_in_days => 30,
        default_keep_results_in_days => 30,
        default_keep_important_logs_in_days => 180,
        default_keep_important_results_in_days => 180,
        default_keep_jobs_in_days => 400,
        default_keep_important_jobs_in_days => 200,
    });
my $parent_keeping_results_forever
  = $parents->create({name => 'parent keeping important results forever', default_keep_important_results_in_days => 0});
my $group_inheriting_equal_limits
  = $groups->create({name => 'group inheriting equal log and result limits', parent_id => $parent_with_own_limits->id});
my $group_inheriting_forever
  = $groups->create(
    {name => 'group inheriting forever important results', parent_id => $parent_keeping_results_forever->id});
my $group_with_own_equal_limits
  = $groups->create(
    {name => 'group with own equal log and result limits', keep_logs_in_days => 45, keep_results_in_days => 45});
my $group_with_results_above_jobs = $groups->create(
    {
        name => 'group with result limit above job limit',
        keep_logs_in_days => 10,
        keep_results_in_days => 100,
        keep_jobs_in_days => 50,
    });
my $group_without_limits = $groups->create({name => 'group without own or parent limits'});
my $group_count = $groups->count;
my $parent_count = $parents->count;
my ($inheriting_parent_id, $own_limits_id, $forever_parent_id)
  = map { $_->id } ($parent_with_own_limits, $group_with_own_equal_limits, $parent_keeping_results_forever);

my $config_dir = tempdir(CLEANUP => 1);
$config_dir->child('openqa.ini')->spew(<<~'END');
[default_group_limits]
log_storage_duration = 10
important_log_storage_duration = 90
result_storage_duration = 21
important_result_storage_duration = 0
job_storage_duration = 500
important_job_storage_duration = 1000
END

my $script = path($Bin, '../script/openqa-audit-retention')->realpath;
$ENV{OPENQA_DATABASE} = 'test';
$ENV{OPENQA_DATABASE_SEARCH_PATH} = $schema_name;
$ENV{OPENQA_CONFIG} = "$config_dir";
$ENV{PGOPTIONS} = '-c default_transaction_read_only=on';

sub run_script (@args) {
    my ($out, $err) = ('', '');
    run [$script, @args], \undef, \$out, \$err, timeout(60);
    return ($? >> 8, $out, $err);
}

sub run_report (@args) {
    my ($exit_code, $out, $err) = run_script(@args);
    is $exit_code, 0, 'script exited successfully';
    is $err, '', 'no errors on stderr' or diag $err;
    return $out;
}

sub json_report () {
    my $json = Cpanel::JSON::XS->new->decode(run_report('--format', 'json'));
    return $json, {map { $_->{name} => $_ } (@{$json->{job_groups}}, @{$json->{parent_groups}})};
}

subtest 'usage' => sub {
    my ($exit_code, $out) = run_script('--help');
    is $exit_code, 0, 'help exits successfully';
    like $out, qr/--format/, 'output format option documented';

    my ($code, undef, $err) = run_script('--format', 'yaml');
    is $code, 1, 'unsupported output format rejected';
    like $err, qr/Unsupported format 'yaml'/, 'unsupported output format explained';
};

subtest 'text output shows one line per group with effective values and their source' => sub {
    my $out = run_report;
    my @lines = grep { length } split /\n/, $out;
    is scalar @lines, $group_count + $parent_count, 'one line per job group and parent group';

    like $out,
qr/^group \Q$own_limits_id\E 'group with own equal log and result limits' \(no parent\): keep_logs_in_days=45\(own\) keep_important_logs_in_days=90\(default\) keep_results_in_days=45\(own\) keep_important_results_in_days=0\(default,forever\) keep_jobs_in_days=500\(default\) keep_important_jobs_in_days=1000\(default\) \[/m,
      'own values and configuration defaults reported with their source';

    like $out,
qr/^parent \Q$inheriting_parent_id\E 'parent with own retention limits' \(no parent\): keep_logs_in_days=30\(own\)/m,
      'parent groups are reported with their default_keep_ values';

    like $out,
qr/'group inheriting forever important results' \(parent \Q$forever_parent_id\E '[^']+'\): keep_logs_in_days=10\(default\).*keep_important_results_in_days=0\(parent,forever\)/m,
      'inherited value references the parent group';
};

subtest 'equal log and result limits are classified as ineffective' => sub {
    my (undef, $records) = json_report;

    is_deeply $records->{'group inheriting equal log and result limits'}->{classifications},
      [qw(logs_not_shorter_than_results important_logs_not_shorter_than_important_results)],
      'group inheriting equal limits from the parent is classified';
    is_deeply $records->{'group with own equal log and result limits'}->{classifications},
      [qw(logs_not_shorter_than_results important_results_gt_important_jobs forever)],
      'group with own equal limits is classified';
    is_deeply [sort @{$records->{'parent with own retention limits'}->{classifications}}],
      [qw(important_logs_not_shorter_than_important_results logs_not_shorter_than_results)],
      'parent group with equal limits is classified';
    is_deeply $records->{'group with result limit above job limit'}->{classifications},
      [qw(results_gt_jobs important_results_gt_important_jobs forever)],
      'result limit above the job limit is classified';
};

subtest 'forever retention inherited from the configuration' => sub {
    my (undef, $records) = json_report;
    my $record = $records->{'group without own or parent limits'};
    is_deeply $record->{settings}->{keep_important_results_in_days}, {value => 0, source => 'default'},
      'forever important results reported with source default';
    is_deeply $record->{forever}, ['keep_important_results_in_days'], 'forever columns reported';
    is_deeply [sort @{$record->{classifications}}],
      [qw(forever important_results_gt_important_jobs)],
      'forever important results above the important job limit classified';
};

subtest 'json output' => sub {
    my $out = run_report('--format', 'json');
    my $json = Cpanel::JSON::XS->new->decode($out);
    is_deeply $json->{config_defaults},
      {
        keep_logs_in_days => 10,
        keep_important_logs_in_days => 90,
        keep_results_in_days => 21,
        keep_important_results_in_days => 0,
        keep_jobs_in_days => 500,
        keep_important_jobs_in_days => 1000,
      },
      'configuration defaults reported';
    is scalar @{$json->{job_groups}}, $group_count, 'all job groups reported';
    is scalar @{$json->{parent_groups}}, $parent_count, 'all parent groups reported';

    my ($inheriting) = grep { $_->{name} eq 'group inheriting equal log and result limits' } @{$json->{job_groups}};
    is $inheriting->{kind}, 'group', 'kind reported';
    is_deeply $inheriting->{parent}, {id => $parent_with_own_limits->id, name => 'parent with own retention limits'},
      'parent group reported';
    is_deeply $inheriting->{settings}->{keep_logs_in_days}, {value => 30, source => 'parent'},
      'value inherited from parent';
    is_deeply $inheriting->{settings}->{keep_jobs_in_days}, {value => 400, source => 'parent'},
      'job limit inherited from parent';

    my ($without_parent) = grep { $_->{name} eq 'group without own or parent limits' } @{$json->{job_groups}};
    is $without_parent->{parent}, undef, 'group without parent reported';
    my $reported_parents = grep { $_->{kind} eq 'parent' } @{$json->{parent_groups}};
    is $reported_parents, $parent_count, 'parent groups tagged';

    like $out, qr/"keep_results_in_days"\s*:\s*21\b/, 'retention values reported as numbers';
    unlike $out, qr/"keep_\w+_in_days"\s*:\s*"/, 'no retention value reported as string';

    is run_report('--format', 'json'), $out, 'json output is stable';
};

subtest 'script performs no writes' => sub {
    my ($exit_code) = run_script('--format', 'json');
    is $exit_code, 0, 'script succeeds with every database connection of the run read-only via PGOPTIONS';
};

done_testing;
