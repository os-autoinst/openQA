#!/usr/bin/env perl -w

# Copyright (C) 2016 SUSE LLC
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

BEGIN {
    unshift @INC, 'lib';
}

use strict;
use OpenQA::Utils;
use Test::More;

is bugurl('bsc#1234'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234', 'bug url is properly expanded';
ok find_bugref('gh#os-autoinst/openQA#1234'), 'github bugref is recognized';
is(find_bugref('bsc#1234 poo#4321'), 'bsc#1234', 'first bugres found');
is_deeply(find_bugrefs('bsc#1234 poo#4321'), ['bsc#1234', 'poo#4321'], 'multiple bugrefs found');
is_deeply(find_bugrefs('bc#1234 #4321'), [], 'no bugrefs found');
is bugurl('gh#os-autoinst/openQA#1234'),                        'https://github.com/os-autoinst/openQA/issues/1234';
is bugurl('poo#1234'),                                          'https://progress.opensuse.org/issues/1234';
is href_to_bugref('https://progress.opensuse.org/issues/1234'), 'poo#1234';
is bugref_to_href('boo#9876'), '<a href="https://bugzilla.opensuse.org/show_bug.cgi?id=9876">boo#9876</a>';
is href_to_bugref('https://github.com/foo/bar/issues/1234'),              'gh#foo/bar#1234';
is href_to_bugref('https://github.com/os-autoinst/os-autoinst/pull/960'), 'gh#os-autoinst/os-autoinst#960',
  'github pull are also transformed same as issues';
is bugref_to_href('gh#foo/bar#1234'), '<a href="https://github.com/foo/bar/issues/1234">gh#foo/bar#1234</a>';
like bugref_to_href('bsc#2345 poo#3456 and more'),
  qr{a href="https://bugzilla.suse.com/show_bug.cgi\?id=2345">bsc\#2345</a> <a href=.*3456.*> and more},
  'bugrefs in text get replaced';
like bugref_to_href('boo#2345,poo#3456'),
  qr{a href="https://bugzilla.opensuse.org/show_bug.cgi\?id=2345">boo\#2345</a>,<a href=.*3456.*},
  'interpunctation is not consumed by href';

subtest 'get current version' => sub {
    use Mojo::File qw(path tempdir tempfile);
    # Let's check that the version matches our versioning scheme.
    # If it's a git version it should be in the form: git-tag-sha1
    # otherwise is a group of 3 decimals followed by a partial sha1: a.b.c.sha1

    my $changelog_dir  = tempdir;
    my $git_dir        = tempdir;
    my $changelog_file = path($changelog_dir, "public")->make_path->child("Changelog");
    my $refs_file      = path($git_dir, ".git")->make_path->child("packed-refs");
    my $head_file      = path($git_dir, ".git", "refs", "heads")->make_path->child("master");
    my $sha_regex      = qr/\b[0-9a-f]{5,40}\b/;

    my $changelog_content = <<'EOT';
-------------------------------------------------------------------
Mon May 08 11:45:15 UTC 2017 - rd-ops-cm@suse.de

- Update to version 4.4.1494239160.9869466:
  * Fix missing space in log debug message (#1307)
  * Register job assets even if one of the assets need to be skipped (#1310)
  * Test whether admin table displays needles which never matched
  * Show needles in admin table which never matched
  * Improve logging in case of upload failure (#1309)
  * Improve product fixtures to prevent dependency warnings
  * Handle wrong/missing job dependencies appropriately
  * clone_job.pl: Print URL of generated job for easy access (#1313)

-------------------------------------------------------------------
Sat Mar 18 20:03:22 UTC 2017 - coolo@suse.com

- bump mojo requirement

-------------------------------------------------------------------
Sat Mar 18 19:31:50 UTC 2017 - rd-ops-cm@suse.de

- Update to version 4.4.1489864450.251306a:
  * Make sure assets in pool are handled correctly
  * Call rsync of tests in a child process and notify webui
  * Move OpenQA::Cache to Worker namespace
  * Trying to make workers.ini more descriptive
  * docs: Add explanation for job priority (#1262)
  * Schedule worker reregistration in case of api-failure
  * Add more logging to job notifications
  * Use host_port when parsing URL
  * Prevent various timer loops
  * Do job cleanup even in case of api failure
EOT

    my $refs_content = <<'EOT';
# pack-refs with: peeled fully-peeled
f8ce111933922cde0c5d11952fbb59b307a700e5 refs/tags/4.0
bb8144fdb128896d0132188c55d298c3905b48aa refs/tags/4.1
87e71451fea9d54927efe9ce3f9e7071fb11e874 refs/tags/4.2
^9953cb8cc89f4e9187f4209035ce2990dbf544cc
ac6dd8d4475f8b7e0d683e64ff49d6d96151fb76 refs/tags/4.3
^11f0541f05d7bbc663ae90d6dedefde8d6f03ff4
EOT

    # Create a valid Changelog and check if result is the expected one
    $changelog_file->spurt($changelog_content);
    is detect_current_version($changelog_dir), '4.4.1494239160.9869466', 'Detect current version from Changelog format';
    like detect_current_version($changelog_dir), qr/(\d+\.\d+\.\d+\.$sha_regex)/, "Version scheme matches";
    $changelog_file->spurt("- Update to version 4.4.1494239160.9869466:\n- Update to version 4.4.1489864450.251306a:");
    is detect_current_version($changelog_dir), '4.4.1494239160.9869466', 'Pick latest version detected in Changelog';

    # Failure detection case for Changelog file
    $changelog_file->spurt("* Do job cleanup even in case of api failure");
    is detect_current_version($changelog_dir), undef, 'Invalid Changelog return no version';
    $changelog_file->spurt("Update to version 3a2.d2d.2ad.9869466:");
    is detect_current_version($changelog_dir), undef, 'Invalid versions in Changelog returns undef';

    # Create a valid Git repository where we can fetch the exact version.
    $head_file->spurt("7223a2408120127ad2d82d71ef1893bbe02ad8aa");
    $refs_file->spurt($refs_content);
    is detect_current_version($git_dir), 'git-4.3-7223a240', 'detect current version from Git repository';
    like detect_current_version($git_dir), qr/(git\-\d+\.\d+\-$sha_regex)/, 'Git version scheme matches';

    # If refs file can't be found or there is no tag present, version should be undef
    unlink($refs_file);
    is detect_current_version($git_dir), undef, "Git ref file missing, version is undef";
    $refs_file->spurt("ac6dd8d4475f8b7e0d683e64ff49d6d96151fb76");
    is detect_current_version($git_dir), undef, "Git ref file shows no tag, version is undef";
};

done_testing;
