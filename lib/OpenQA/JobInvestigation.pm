# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::JobInvestigation;

use Mojo::Base -strict, -signatures;

use Exporter 'import';
use List::Util 'uniq';
use OpenQA::Utils 'run_cmd_with_log_return_error';

our @EXPORT_OK = qw(
  RETURN_CODE_TIMEOUT_EXCEEDED tree_file git_has_commit git_timed git_failure_message git_tree tagged_needles
  annotate_pull_requests failed_test_files failed_needle_files
);

use constant JOB_INVESTIGATE_PULL_REQUESTS_MAX => 200;
use constant RETURN_CODE_TIMEOUT_EXCEEDED => 124;    # see `man timeout`

# returns the longest suffix of $path that is a file in the git tree (a hash reference of paths)
sub tree_file ($tree, $path) {
    my @parts = grep { length } split m{/}, $path // '';
    for (; @parts; shift @parts) {
        my $rel = join '/', @parts;
        return $rel if $tree->{$rel};
    }
    return undef;
}

sub git_has_commit ($deadline, $dir, $hash) {
    return 0 unless defined $hash && $hash =~ m/^[0-9a-f]{7,40}$/i;
    return git_timed($deadline, $dir, ['cat-file', '-e', "$hash^{commit}"])->{status};
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
    my $res = git_timed($deadline, $dir, ['ls-tree', '-r', '-z', $hash]);
    unless ($res->{status}) {
        return (undef,
            $res->{return_code} == RETURN_CODE_TIMEOUT_EXCEEDED
            ? git_failure_message(RETURN_CODE_TIMEOUT_EXCEEDED)
            : $unknown);
    }
    return (+{map { $_ => 1 } map { /^100\d{3} blob \S+\t(.*)$/s ? $1 : () } split /\0/, $res->{stdout}});
}

# returns the paths of the needles in the commit $hash that have one of the $tags, or the git error message
sub tagged_needles ($deadline, $dir, $tree, $hash, $tags) {
    my $pattern = join '|', map { s/([.+])/\\$1/gr } @$tags;
    my @cmd = ('grep', '-l', '-z', '-E', '-e', qq{"($pattern)"}, $hash, '--', '*.json');
    my $res = git_timed($deadline, $dir, \@cmd, expected_return_codes => {0 => 1, 1 => 1});
    my $return_code = $res->{return_code} // 255;
    return (undef, git_failure_message($return_code)) if $return_code > 1;
    return ([grep { $tree->{$_} } map { s/^\Q$hash\E://r } split /\0/, $res->{stdout}]);
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
        my @found = map { tree_file($tree, $_) // () } @$traced;
        push @files, @found ? @found : (tree_file($tree, $script) // ());
    }
    return [uniq @files];
}

# the needles considered by failed screen checks, their pngs and the needles with the tags of those checks
sub failed_needle_files ($tree, $needles, $tagged) {
    my @files = map { tree_file($tree, $_) // () } @$needles;
    @files = uniq @files, @$tagged;
    return [map { my $png = s/\.json$/.png/r; ($_, $png ne $_ && $tree->{$png} ? $png : ()) } @files];
}

1;
