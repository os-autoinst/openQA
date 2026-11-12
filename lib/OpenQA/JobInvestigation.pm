# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobInvestigation;

use Mojo::Base -strict, -signatures;

use DateTime;
use Exporter 'import';
use List::Util 'uniq';
use OpenQA::App;
use OpenQA::Log 'log_warning';
use OpenQA::Utils qw(run_cmd_with_log_return_error effective_distri needledir testcasedir);

our @EXPORT_OK = qw(
  RETURN_CODE_TIMEOUT_EXCEEDED git_has_commit git_timed git_failure_message git_tree tagged_needles
  annotate_pull_requests failed_test_files failed_needle_files git_log_diff git_diff failure_investigation
);

use constant JOB_INVESTIGATE_PULL_REQUESTS_MAX => 200;
use constant JOB_INVESTIGATE_GIT_TIMEOUT => 20;
use constant JOB_INVESTIGATE_FAILURE_WINDOW_DAYS => 5;
use constant JOB_INVESTIGATE_FAILURE_MODULES_MAX => 3;
use constant JOB_INVESTIGATE_FAILURE_FILES_MAX => 50;
use constant RETURN_CODE_TIMEOUT_EXCEEDED => 124;    # see `man timeout`
use constant EMPTY_TREE => '4b825dc642cb6eb9a060e54bf8d69288fbee4904';
use constant TAGGED_NEEDLES_CHUNK => 500;

# unknown commits (128) and timeouts are handled by the callers, so git's output is not logged as a problem
my %PROBE_CODES = (0 => 1, 124 => 1, 128 => 1);

# returns the longest suffix of $path that is a file in the git tree (a hash reference of paths)
sub _tree_file ($tree, $path) {
    my @parts = grep { length } split m{/}, $path // '';
    for (; @parts; shift @parts) {
        my $rel = join '/', @parts;
        return $rel if $tree->{$rel};
    }
    return undef;
}

sub _git_timeout () {
    OpenQA::App->singleton->config->{global}->{job_investigate_git_timeout} // JOB_INVESTIGATE_GIT_TIMEOUT;
}

sub git_has_commit ($deadline, $dir, $hash) {
    return 0 unless defined $hash && $hash =~ m/^[0-9a-f]{7,40}$/i;
    return git_timed($deadline, $dir, ['cat-file', '-e', "$hash^{commit}"], expected_return_codes => \%PROBE_CODES)
      ->{status};
}

# runs git within the time left until $deadline (epoch seconds), which is shared by all commands of a request
sub git_timed ($deadline, $dir, $args, %options) {
    my $left = $deadline - time;
    return {status => 0, return_code => RETURN_CODE_TIMEOUT_EXCEEDED, stdout => '', stderr => ''} if $left <= 0;
    return run_cmd_with_log_return_error(['timeout', $left, 'git', '-C', $dir, @$args], stdout => 'trace', %options);
}

sub git_failure_message ($return_code) {
    return $return_code == RETURN_CODE_TIMEOUT_EXCEEDED
      ? 'Computing changes timed out'
      : 'Cannot list changes because of a git problem';
}

# returns the files of the commit $hash in $dir as hash reference or, as second value, why that is not possible
sub git_tree ($deadline, $dir, $hash) {
    my $unknown = 'Tested git commit is unknown or not available on this host, cannot list changes';
    return (undef, $unknown) unless defined $hash && $hash =~ m/^[0-9a-f]{7,40}$/i;
    my $res = git_timed($deadline, $dir, ['ls-tree', '-r', '-z', $hash], expected_return_codes => \%PROBE_CODES);
    unless ($res->{status}) {
        return (undef,
            $res->{return_code} == RETURN_CODE_TIMEOUT_EXCEEDED
            ? git_failure_message(RETURN_CODE_TIMEOUT_EXCEEDED)
            : $unknown);
    }
    return (+{map { $_ => 1 } map { /^100\d{3} blob \S+\t(.*)$/s ? $1 : () } split /\0/, $res->{stdout}});
}

# returns the needles that changed between the last good commit $prev_hash, else the last commit before $since
# (epoch seconds), and $hash and have one of the $tags at either end, or the git error message
sub tagged_needles ($deadline, $dir, $hash, $prev_hash, $since, $tags) {
    my $base = git_has_commit($deadline, $dir, $prev_hash) ? $prev_hash : undef;
    unless ($base) {
        my @cmd = ('rev-list', '-1', "--before=$since", $hash);
        my $res = git_timed($deadline, $dir, \@cmd, expected_return_codes => \%PROBE_CODES);
        return (undef, git_failure_message($res->{return_code} // 255)) unless $res->{status};
        $base = $res->{stdout} =~ m/^([0-9a-f]{40})$/m ? $1 : EMPTY_TREE;
    }
    my @cmd = ('diff', '--name-only', '--relative', '-z', $base, $hash, '--', '*.json');
    my $changed = git_timed($deadline, $dir, \@cmd, expected_return_codes => \%PROBE_CODES);
    return (undef, git_failure_message($changed->{return_code} // 255)) unless $changed->{status};
    my @files = split /\0/, $changed->{stdout};
    my $pattern = '"(' . join('|', map { s/([.+])/\\$1/gr } @$tags) . ')"';
    my @revs = $base eq EMPTY_TREE ? ($hash) : ($hash, $base);
    my @tagged;
    while (my @chunk = splice @files, 0, TAGGED_NEEDLES_CHUNK) {
        for my $rev (@revs) {
            my @grep = ('grep', '-l', '-z', '-E', '-e', $pattern, $rev, '--', map { ":(literal)$_" } @chunk);
            my $res = git_timed($deadline, $dir, \@grep, expected_return_codes => {0 => 1, 1 => 1, 124 => 1});
            my $return_code = $res->{return_code} // 255;
            return (undef, git_failure_message($return_code)) if $return_code > 1;
            push @tagged, map { s/^\Q$rev\E://r } split /\0/, $res->{stdout};
        }
    }
    return ([uniq @tagged]);
}

# adds " (#<number>)" to commits that were merged via a "Merge pull request #<number>" merge commit, as far as
# the time until $options{deadline} allows
sub annotate_pull_requests ($dir, $log, $range, %options) {
    my %pending = map { $_ => 1 } $log =~ /^([0-9a-f]{10}) (?!.*\(#\d+\)$)/mg;
    return $log unless %pending;
    my $deadline = $options{deadline};
    my @since = $options{since} ? "--since=$options{since}" : ();
    # commits on the first-parent line were not merged via pull request and would make us search all merges
    my $direct = git_timed($deadline, $dir, ['rev-list', '--first-parent', '--no-merges', @since, $range]);
    return $log unless $direct->{status};
    delete $pending{$_} for $direct->{stdout} =~ /^([0-9a-f]{10})/mg;
    return $log unless %pending;
    my @merges = ('log', '--first-parent', '--merges', '--pretty=%H %s', '-' . JOB_INVESTIGATE_PULL_REQUESTS_MAX);
    my $merges = git_timed($deadline, $dir, [@merges, @since, $range]);
    return $log unless $merges->{status};
    my %pull_request;
    for my $merge (split /\n/, $merges->{stdout}) {
        next unless $merge =~ m/^([0-9a-f]{40}) Merge pull request #(\d+) /;
        my ($merge_hash, $number) = ($1, $2);
        my $commits = git_timed($deadline, $dir, ['rev-list', '--no-merges', "$merge_hash^1..$merge_hash"]);
        last unless $commits->{status};
        $pull_request{$_} = $number for grep { delete $pending{$_} } $commits->{stdout} =~ /^([0-9a-f]{10})/mg;
        last unless %pending;
    }
    return $log =~ s/^([0-9a-f]{10}) (.*)$/exists $pull_request{$1} ? "$1 $2 (#$pull_request{$1})" : "$1 $2"/mger;
}

# the tested files of the failed modules, i.e. those of their stack traces, else the module's own file
sub failed_test_files ($tree, $modules) {
    my @files;
    for my $module (@$modules) {
        my ($traced, $script) = @$module;
        my @found = map { _tree_file($tree, $_) // () } @$traced;
        push @files, @found ? @found : (_tree_file($tree, $script) // ());
    }
    return [uniq @files];
}

# the needles considered by failed screen checks, their pngs and the needles with the tags of those checks
sub failed_needle_files ($tree, $needles, $tagged) {
    my @files = map { _tree_file($tree, $_) // () } @$needles;
    @files = uniq @files, @$tagged;
    return [map { my $png = s/\.json$/.png/r; ($_, $png ne $_ && $tree->{$png} ? $png : ()) } @files];
}

sub git_log_diff ($dir, $refspec_range, %options) {
    return "Invalid range $refspec_range" if $refspec_range =~ m/UNKNOWN|unreadable git hash/;
    my $limit = $options{limit};
    my $stat = $options{stat} // '300,200';
    my @abbrev = $options{abbrev} ? "--abbrev=$options{abbrev}" : ();
    my @since = $options{since} ? "--since=$options{since}" : ();
    my @paths = $options{paths} ? ('--', @{$options{paths}}) : ();
    my @timeout = $options{timeout} ? ('timeout', $options{timeout}) : ();
    my $res = run_cmd_with_log_return_error(
        [
            @timeout, 'git', '-C', $dir, 'log', ($limit ? "-$limit" : ()),
            "--stat=$stat", '--pretty=oneline',
            '--abbrev-commit', @abbrev, '--no-merges', @since, $refspec_range, @paths
        ],
        stdout => 'trace'
    );
    ${$options{failed}} = $res->{return_code} // 255 if $options{failed} && !$res->{status};
    # regardless of success or not the output contains the information we need
    return $res->{stdout} . $res->{stderr};
}

sub git_diff ($dir, $refspec_range, %options) {
    return "Invalid range $refspec_range" if $refspec_range =~ m/UNKNOWN|unreadable git hash/;
    my $limit = $options{limit} // 0;
    my $stat = $options{stat} // '300,200';
    my $timeout = _git_timeout();
    my $cmd = ['git', '-C', $dir, 'rev-list', '--count', $refspec_range];
    my $res = run_cmd_with_log_return_error($cmd);
    my $out = $res->{stdout} . $res->{stderr};
    if ($res->{return_code}) {
        return "Cannot display diff: $1" if $res->{stderr} =~ m/(invalid revision range)/i;
        log_warning "Problem with [@$cmd] rc=$res->{return_code}: $out";
        return 'Cannot display diff because of a git problem';
    }
    chomp(my $count = $res->{stdout});
    if ($count =~ tr/0-9//c) {
        log_warning "Problem with [@$cmd]: returned non-numeric string '$count'";
        return 'Cannot display diff because of a git problem';
    }
    return "Too many commits ($count) to create a diff between $refspec_range (maximum: $limit)" if $count > $limit;

    $cmd = ['timeout', $timeout, 'git', '-C', $dir, 'diff', "--stat=$stat", $refspec_range];
    $res = run_cmd_with_log_return_error($cmd, stdout => 'trace');
    $out = $res->{stdout} . $res->{stderr};
    if (my $return_code = $res->{return_code}) {
        my $is_timeout = $return_code == RETURN_CODE_TIMEOUT_EXCEEDED;
        log_warning "Problem with [@$cmd] rc=$return_code: $out" unless $is_timeout;
        return $is_timeout ? 'Computing diff timed out' : 'Cannot display diff because of a git problem';
    }
    return $out;
}

# returns the test code paths, needle paths and tags involved in the failed modules, found via their stack
# traces and failed screen steps, as array references; for the test code as per module [trace paths, script]
sub failed_module_inputs ($job) {
    my (@modules, @needles, @tags);
    my %attrs = (order_by => 't_updated', rows => JOB_INVESTIGATE_FAILURE_MODULES_MAX);
    my $modules = $job->modules->search({result => 'failed'}, \%attrs);
    while (my $module = $modules->next) {
        my @steps = grep { ($_->{result} // '') eq 'fail' } @{$module->results->{details} // []};
        my @traced = map { /(\S+\.(?:pm|py)) line \d+/g } map { $_->{text_data} // () } @steps;
        push @modules, [\@traced, $module->script];
        for my $step (@steps) {
            push @needles, map { $_->{json} // () } @{$step->{needles} // []};
            my @missing = ($step->{text_data} // '') =~ /no candidate needle with tag\(s\) '([^']+)'/g;
            push @tags, grep { /^[A-Za-z0-9_.:+-]+$/ } @{$step->{tags} // []}, map { split /[\s,]+/ } @missing;
        }
    }
    return \@modules, [uniq @needles], [uniq @tags];
}

sub failure_window_start ($job) {
    return ($job->t_started || DateTime->now)->subtract(days => JOB_INVESTIGATE_FAILURE_WINDOW_DAYS)->epoch;
}

# lists commits to the $files between the last good and this job, or else within the window before this job
# started; returns $none if there are none or a message if git failed
sub failure_log ($dir, $self_hash, $prev_hash, $files, $none, %options) {
    return $none unless @$files;
    my $deadline = $options{deadline};
    my %git = (limit => $options{limit}, abbrev => 10, paths => [map { ":(literal)$_" } @$files]);
    my $has_range = git_has_commit($deadline, $dir, $prev_hash);
    my $range = $has_range ? "$prev_hash..$self_hash" : $self_hash;
    $git{since} = $options{since} unless $has_range;
    my $left = $deadline - time;
    return git_failure_message(RETURN_CODE_TIMEOUT_EXCEEDED) if $left <= 0;
    my $failed;
    my $log = git_log_diff($dir, $range, %git, timeout => $left, failed => \$failed);
    return git_failure_message($failed) if $failed;
    return $log ? annotate_pull_requests($dir, $log, $range, since => $git{since}, deadline => $deadline) : $none;
}

# commits to the files named in the stack traces and to the needles of the failed screen steps
sub failure_investigation ($job, $inv, $self_vars, $prev_vars, %args) {
    return unless $job->has_failed_modules && $job->result_dir && %$self_vars;
    my $deadline = time + _git_timeout();
    my $effective_distri = effective_distri($self_vars);
    my $casedir = testcasedir($effective_distri, $job->VERSION);
    my $needles_dir = needledir($effective_distri, $job->VERSION);
    my ($modules, $needles, $tags) = failed_module_inputs($job);
    my ($test_hash, $needles_hash) = map { $self_vars->{$_} } qw(TEST_GIT_HASH NEEDLES_GIT_HASH);
    my ($prev_test, $prev_needles) = map { $prev_vars->{$_} } qw(TEST_GIT_HASH NEEDLES_GIT_HASH);
    my $since = failure_window_start($job);
    my %log = (limit => $args{git_limit}, deadline => $deadline, since => $since);
    if (@$modules) {
        my ($tree, $error) = git_tree($deadline, $casedir, $test_hash);
        my $files = $tree ? failed_test_files($tree, $modules) : [];
        splice @$files, JOB_INVESTIGATE_FAILURE_FILES_MAX;
        my $none = 'No recent changes to the test files involved in the failure';
        $inv->{failure_test_log} = $error || failure_log($casedir, $test_hash, $prev_test, $files, $none, %log)
          if $error || @$files;
    }
    if (@$needles || @$tags) {
        my ($tree, $error) = git_tree($deadline, $needles_dir, $needles_hash);
        my $tagged = [];
        ($tagged, $error) = tagged_needles($deadline, $needles_dir, $needles_hash, $prev_needles, $since, $tags)
          if $tree && @$tags;
        my $files = $tree && !$error ? failed_needle_files($tree, $needles, $tagged) : [];
        splice @$files, JOB_INVESTIGATE_FAILURE_FILES_MAX;
        my $none = 'No recent changes to the needles involved in the failure';
        $inv->{failure_needles_log}
          = $error || failure_log($needles_dir, $needles_hash, $prev_needles, $files, $none, %log);
    }
}

1;
