#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Test::MockModule;
use Test::Output qw(combined_like output_from);

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Mojo::File qw(path tempdir);
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '30';

require "$FindBin::Bin/../script/openqa-archive-jobs";

my $schema = OpenQA::Test::Case->new->init_data;
my $jobs = $schema->resultset('Jobs');

sub options (@args) {
    local @ARGV = @args;
    return main::parse_options();
}

sub create_result_dir ($job) {
    my $result_dir = path($job->result_dir)->make_path;
    path($result_dir, 'autoinst-log.txt')->spew("fake log\n");
    return $result_dir;
}

sub archived_dir ($job) {
    return $job->add_result_dir_prefix($job->remove_result_dir_prefix($job->result_dir), 1);
}

subtest 'parsing command line options' => sub {
    my ($opt, $usage) = options();
    ok !$opt->help && !$opt->dry_run && !defined $opt->file, 'no options specified by default';
    like $usage->text, qr/--dry-run/, 'usage mentions --dry-run';
    like $usage->text, qr/--file/, 'usage mentions --file';

    ($opt, $usage) = options(qw(--file ids.txt --dry-run));
    is $opt->file, 'ids.txt', 'file option parsed';
    is $opt->dry_run, 1, 'dry-run option parsed';
    ($opt) = options('--help');
    is $opt->help, 1, 'help option parsed';
};

subtest 'parsing job IDs' => sub {
    is_deeply [main::parse_ids('1 2,3', "4\n5")], [1, 2, 3, 4, 5], 'IDs separated by whitespace and commas';
    is_deeply [main::parse_ids(' , ', '')], [], 'empty tokens ignored';
    is_deeply [main::parse_ids(' 42 ')], [42], 'surrounding whitespace ignored';
    throws_ok { main::parse_ids('42 foo') } qr/Invalid job ID 'foo'/, 'invalid job ID rejected';
    throws_ok { main::parse_ids('42 -1') } qr/Invalid job ID '-1'/, 'negative job ID rejected';
};

subtest 'reading job IDs from arguments, files and STDIN' => sub {
    my ($opt) = options();
    is_deeply [main::read_job_ids($opt, qw(1 1 2))], [1, 2], 'duplicate IDs removed';

    my $file = tempdir->child('ids.txt')->spew("3,4\n5 3\n");
    ($opt) = options('--file', $file->to_string);
    is_deeply [main::read_job_ids($opt, 1)], [1, 3, 4, 5], 'IDs from file and arguments combined and deduplicated';

    ($opt) = options('--file', '-');
    {
        local *STDIN;
        my $input = "6 7\n6\n";
        open STDIN, '<', \$input or die "Unable to fake STDIN: $!";
        is_deeply [main::read_job_ids($opt)], [6, 7], 'IDs read from STDIN';
    }

    ($opt) = options('--file', $file->to_string);
    throws_ok { main::read_job_ids($opt, 'invalid') } qr/Invalid job ID 'invalid'/,
      'invalid job ID from arguments rejected';
};

subtest 'previewing jobs' => sub {
    my $base = tempdir;
    local $ENV{OPENQA_BASEDIR} = $base;

    my $job = $jobs->find(99937);
    my $result_dir = create_result_dir($job);
    is_deeply [main::preview_job($job)],
      [archived => "would move $result_dir to @{[archived_dir($job)]}"],
      'job with result directory would be moved';

    my $job_without_dir = $jobs->find(99945);
    is_deeply [main::preview_job($job_without_dir)],
      [flagged => 'has no result directory, would only be flagged as archived'],
      'job without result directory would only be flagged';
};

subtest 'archiving a single job' => sub {
    my $base = tempdir;
    local $ENV{OPENQA_BASEDIR} = $base;

    subtest 'actual archiving' => sub {
        my $job = $jobs->find(99938);
        my $result_dir = create_result_dir($job);
        my $archived_dir = archived_dir($job);

        is_deeply [main::archive_job($schema, 99938, 0)], [archived => "archived to $archived_dir"], 'job archived';
        ok !-e $result_dir, 'original result directory removed';
        ok -e path($archived_dir, 'autoinst-log.txt'), 'result file moved to archive';
        $job->discard_changes;
        is $job->archived, 1, 'job flagged as archived in database';
        is $job->result_dir, $archived_dir, 'archive is now considered the result directory';

        is_deeply [main::archive_job($schema, 99938, 0)], [skipped => 'already archived, skipping'],
          'already archived job skipped';
    };

    subtest 'job does not exist' => sub {
        is_deeply [main::archive_job($schema, 999_999, 0)], [skipped => 'does not exist, skipping'],
          'non-existent job skipped';
    };

    subtest 'job not finished' => sub {
        is_deeply [main::archive_job($schema, 99963, 0)], [skipped => 'not finished (state: running), skipping'],
          'running job skipped';
    };

    subtest 'dry run' => sub {
        my $job = $jobs->find(99926);
        my $result_dir = create_result_dir($job);
        my $archived_dir = archived_dir($job);

        is_deeply [main::archive_job($schema, 99926, 1)],
          [archived => "would move $result_dir to $archived_dir"], 'archiving only previewed';
        ok -d $result_dir, 'result directory still present';
        ok !-e $archived_dir, 'archive directory not created';
        $job->discard_changes;
        is $job->archived, 0, 'job not flagged as archived in database';
    };

    subtest 'job without result directory' => sub {
        my $job = $jobs->find(99945);
        is_deeply [main::archive_job($schema, 99945, 0)],
          [flagged => 'no result directory, flagged as archived'], 'job only flagged as archived';
        $job->discard_changes;
        is $job->archived, 1, 'job flagged as archived in database';
    };

    subtest 'job archived or changed meanwhile' => sub {
        my $jobs_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
        $jobs_mock->redefine(archive => sub { undef });
        is_deeply [main::archive_job($schema, 99946, 0)],
          [skipped => 'skipped (archived or changed meanwhile)'], 'job skipped if archive() returns undef';
    };

    subtest 'archiving fails' => sub {
        my $jobs_mock = Test::MockModule->new('OpenQA::Schema::Result::Jobs');
        $jobs_mock->redefine(archive => sub { die "fake archiving failure\n" });
        throws_ok { main::archive_job($schema, 99946, 0) } qr/fake archiving failure/, 'error propagated';
    };
};

subtest 'archiving multiple jobs and printing summary' => sub {
    my $base = tempdir;
    local $ENV{OPENQA_BASEDIR} = $base;
    create_result_dir($jobs->find(99937));

    my $count;
    my ($stdout, $stderr) = output_from {
        $count = main::archive_jobs($schema, [99937, 99945, 99963, 999_999], 1);
    };
    is_deeply $count, {archived => 1, flagged => 1, skipped => 2, failed => 0}, 'outcomes counted'
      or always_explain $count;
    is $stderr, '', 'no errors logged';
    like $stdout, qr{^\[1/4\] job 99937: would move }m, 'archived preview printed';
    like $stdout, qr{^\[2/4\] job 99945: has no result directory, would only be flagged as archived$}m,
      'flagged preview printed';
    like $stdout, qr{^\[3/4\] job 99963: not finished \(state: running\), skipping$}m, 'not finished job printed';
    like $stdout, qr{^\[4/4\] job 999999: does not exist, skipping$}m, 'non-existent job printed';

    combined_like { main::print_summary($count, 1) }
    qr{^Summary: archived: 1, flagged: 1, skipped: 2, failed: 0 \(dry run\)$}m, 'summary printed for dry run';
    combined_like { main::print_summary($count, 0) }
    qr{^Summary: archived: 1, flagged: 1, skipped: 2, failed: 0$}m, 'summary printed';

    subtest 'failure while archiving' => sub {
        my $archive_mock = Test::MockModule->new('main');
        $archive_mock->redefine(archive_job => sub { die "fake archiving error\n" });
        my $failed_count;
        my ($stdout, $stderr) = output_from {
            $failed_count = main::archive_jobs($schema, [99937, 99945], 0);
        };
        is_deeply $failed_count, {archived => 0, flagged => 0, skipped => 0, failed => 2}, 'failures counted'
          or always_explain $failed_count;
        is $stdout, '', 'nothing printed to STDOUT';
        like $stderr, qr{^\[1/2\] job 99937: failed: fake archiving error$}m, 'first failure logged';
        like $stderr, qr{^\[2/2\] job 99945: failed: fake archiving error$}m, 'second failure logged';
    };
};

subtest 'main entry point' => sub {
    subtest 'help' => sub {
        local @ARGV = ('--help');
        combined_like { is main::main(), 0 } qr/Archive the results of the specified openQA jobs/,
          'help output printed';
    };

    subtest 'no job IDs' => sub {
        local @ARGV = ();
        combined_like { is main::main(), 1 } qr/No job IDs specified/, 'error and usage printed';
    };

    subtest 'dry run' => sub {
        my $base = tempdir;
        local $ENV{OPENQA_BASEDIR} = $base;
        create_result_dir($jobs->find(99937));
        local @ARGV = ('--dry-run', 99937);

        my ($stdout, $stderr) = output_from { is main::main(), 0, 'exit code 0' };
        is $stderr, '', 'no errors logged';
        like $stdout, qr/^Summary: archived: 1, flagged: 0, skipped: 0, failed: 0 \(dry run\)$/m, 'summary printed';
    };

    subtest 'failures are reflected in the exit code' => sub {
        my $archive_mock = Test::MockModule->new('main');
        $archive_mock->redefine(archive_job => sub { die "fake failure\n" });
        local @ARGV = (99938);

        my ($stdout, $stderr) = output_from { is main::main(), 1, 'exit code 1' };
        like $stderr, qr/job 99938: failed: fake failure/, 'error logged';
        like $stdout, qr/^Summary: archived: 0, flagged: 0, skipped: 0, failed: 1$/m, 'summary printed';
    };
};

done_testing;
