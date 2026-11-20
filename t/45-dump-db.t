# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;
use Test::Warnings ':report_warnings';

use FindBin '$Bin';
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '30';
use IPC::Run qw(run timeout);
use Mojo::File qw(tempdir);
use POSIX qw(strftime);
use Time::Seconds;

my $dump_script = "$Bin/../script/dump-db";
ok -x $dump_script, 'script/dump-db is executable';

sub run_dump ($env = {}) {
    my ($in, $out, $err);
    local %ENV = (%ENV, %$env);
    my $success = eval { run [$dump_script], \$in, \$out, \$err, timeout(10); };
    return ($success, $out, $err, $? >> 8);
}

sub leftover_tmp ($dir) {
    return [grep { /^\.\d{4}-\d{2}-\d{2}\.dump\.tmp\./ } map { $_->basename } @{$dir->list({hidden => 1})}];
}

my $mock_bin = tempdir;
my $mock_pg_dump = $mock_bin->child('pg_dump');
$mock_pg_dump->spurt(<<'SH');
#!/bin/bash
target=""
while [[ $# -gt 0 ]]; do
    if [[ "$1" == "-f" ]]; then
        target="$2"
        shift 2
    else
        shift
    fi
done

if [[ -n "${MOCK_PG_DUMP_FAIL:-}" ]]; then
    [[ -n "$target" ]] && echo "corrupted-in-flight-dump" > "$target"
    exit 1
fi

if [[ -n "${MOCK_PG_DUMP_SIGNAL:-}" ]]; then
    [[ -n "$target" ]] && echo "signal-in-flight-dump" > "$target"
    target_pid="${target##*.}"
    kill -TERM "$target_pid"
    exit 1
fi

[[ -n "$target" ]] && echo "valid-dump-content" > "$target"
exit 0
SH
chmod 0755, "$mock_pg_dump";

my $test_env = {PATH => "$mock_bin:$ENV{PATH}"};
my $today_dump = strftime('%Y-%m-%d.dump', localtime);

subtest 'Atomic success creates final dump and leaves no temp file' => sub {
    my $dump_dir = tempdir;
    my ($success, $out, $err, $exit) = run_dump({%$test_env, DUMP_FOLDER => "$dump_dir"});
    ok $success, 'dump-db succeeds with mock pg_dump';
    is $exit, 0, 'dump-db exits with 0 on success';

    my $final_file = $dump_dir->child($today_dump);
    ok -f $final_file, "dump file $today_dump exists";
    is $final_file->slurp, "valid-dump-content\n", 'dump file contains expected content';

    is scalar @{leftover_tmp($dump_dir)}, 0, 'no hidden temporary dump files remain after success';
};

subtest 'Atomic failure preserves existing dump and cleans up temp file' => sub {
    my $dump_dir = tempdir;
    my $final_file = $dump_dir->child($today_dump);
    $final_file->spurt("original-intact-dump\n");

    my $fail_env = {%$test_env, DUMP_FOLDER => "$dump_dir", MOCK_PG_DUMP_FAIL => '1'};
    my ($success, $out, $err, $exit) = run_dump($fail_env);
    ok !$success, 'dump-db fails when pg_dump fails';
    isnt $exit, 0, 'dump-db exits with non-zero when pg_dump fails';

    ok -f $final_file, "pre-existing $today_dump still exists";
    is $final_file->slurp, "original-intact-dump\n", 'original dump remains byte-identical after failed run';

    is scalar @{leftover_tmp($dump_dir)}, 0, 'temporary in-flight dump was removed by trap on failure';
};

subtest 'Signal termination triggers cleanup and exits with signal exit code' => sub {
    my $dump_dir = tempdir;
    my $sig_env = {%$test_env, DUMP_FOLDER => "$dump_dir", MOCK_PG_DUMP_SIGNAL => '1'};
    my ($success, $out, $err, $exit) = run_dump($sig_env);
    ok !$success, 'dump-db fails on SIGTERM';
    is $exit, 143, 'dump-db exits with 143 on SIGTERM';

    is scalar @{leftover_tmp($dump_dir)}, 0, 'temporary in-flight dump was removed by trap on signal';
};

subtest 'Pruning removes dumps older than retention and stale tmp files' => sub {
    my $dump_dir = tempdir;

    my $old_dump = $dump_dir->child('old.dump');
    $old_dump->spurt("old-dump\n");
    my $old_time = time - (10 * ONE_DAY);
    utime $old_time, $old_time, "$old_dump";

    my $recent_dump = $dump_dir->child('recent.dump');
    $recent_dump->spurt("recent-dump\n");
    my $recent_time = time - (2 * ONE_DAY);
    utime $recent_time, $recent_time, "$recent_dump";

    my $stale_tmp = $dump_dir->child('.stale.dump.tmp.999');
    $stale_tmp->spurt("stale-tmp\n");
    my $stale_time = time - (ONE_DAY + ONE_HOUR);
    utime $stale_time, $stale_time, "$stale_tmp";

    my $active_tmp = $dump_dir->child('.active.dump.tmp.111');
    $active_tmp->spurt("active-tmp\n");
    my $active_time = time - ONE_HOUR;
    utime $active_time, $active_time, "$active_tmp";

    my $non_dump = $dump_dir->child('notes.txt');
    $non_dump->spurt("important-notes\n");
    utime $old_time, $old_time, "$non_dump";

    my ($success, $out, $err, $exit) = run_dump({%$test_env, DUMP_FOLDER => "$dump_dir", DAYS_TO_KEEP => '5'});
    ok $success, 'dump-db with retention from environment succeeds';
    is $exit, 0, 'dump-db exits with 0';

    ok !-f $old_dump, 'dump older than DAYS_TO_KEEP was pruned';
    ok -f $recent_dump, 'dump newer than DAYS_TO_KEEP was preserved';
    ok !-f $stale_tmp, 'stale temporary file older than 1 day was pruned';
    ok -f $active_tmp, 'active temporary file newer than 1 day was preserved';
    ok -f $non_dump, 'non-dump file was not pruned even if older than DAYS_TO_KEEP';
    ok -f $dump_dir->child($today_dump), 'new daily dump was successfully created';
};

done_testing;
