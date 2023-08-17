#!/usr/bin/env perl
# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

# define test helper to check for exit code
our $exit_handler = sub { CORE::exit $_[0] };
BEGIN {
    *CORE::GLOBAL::exit = sub (;$) { $exit_handler->(@_ ? 0 + $_[0] : 0) }
}
sub exit_code(&) {
    my $exit_code;
    local $exit_handler = sub { $exit_code = $_[0] };
    shift->();
    return $exit_code;
}

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils (qw(:DEFAULT prjdir sharedir resultdir assetdir imagesdir base_host random_string random_hex),
    qw(download_rate download_speed usleep_backoff));
use OpenQA::Task::SignalGuard;
use OpenQA::Test::Utils 'redirect_output';
use OpenQA::Test::TimeLimit '10';
use Scalar::Util 'reftype';
use Test::MockObject;
use Mojo::File qw(path tempdir tempfile);

subtest 'service ports' => sub {
    local $ENV{OPENQA_BASE_PORT} = undef;
    is service_port('webui'), 9526, 'webui port';
    is service_port('websocket'), 9527, 'websocket port';
    is service_port('livehandler'), 9528, 'livehandler port';
    is service_port('scheduler'), 9529, 'scheduler port';
    is service_port('cache_service'), 9530, 'cache service port';
    local $ENV{OPENQA_BASE_PORT} = 9530;
    is service_port('webui'), 9530, 'webui port';
    is service_port('websocket'), 9531, 'websocket port';
    is service_port('livehandler'), 9532, 'livehandler port';
    is service_port('scheduler'), 9533, 'scheduler port';
    is service_port('cache_service'), 9534, 'cache service port';
    eval { service_port('unknown') };
    like $@, qr/Unknown service: unknown/, 'unknown port';
};

subtest 'set listen address' => sub {
    local $ENV{MOJO_LISTEN} = undef;
    set_listen_address(9526);
    like $ENV{MOJO_LISTEN}, qr/127\.0\.0\.1:9526/, 'address set';
    set_listen_address(9527);
    unlike $ENV{MOJO_LISTEN}, qr/127\.0\.0\.1:9527/, 'not changed';
};

subtest 'random number generator' => sub {
    my $r = random_string;
    my $r2 = random_string;
    is(length($r), 16, "length 16");
    like($r, qr/^\w+$/a, "random_string only consists of word characters");
    is(length($r), length($r2), "same length");
    isnt($r, $r2, "random_string produces different results");

    $r = random_string 32;
    $r2 = random_string 32;
    is(length($r), 32, "length 32");
    like($r, qr/^\w+$/a, "random_string only consists of word characters");
    is(length($r), length($r2), "same length");
    isnt($r, $r2, "random_string produces different results");

    is(length(random_hex), 16, 'default length 16');
    $r = random_hex 97;
    $r2 = random_hex 97;
    is(length($r), 97, "length 97");
    like($r, qr/^[0-9A-F]+$/a, "random_hex only consists of hex characters");
    is(length($r), length($r2), "same length");
    isnt($r, $r2, "random_hex produces different results");
};

subtest 'download speed' => sub {
    is download_rate([1638459407, 528237], [1638459408, 628237], 1024), '930.91';
    is download_rate([1638459407, 528237], [1638459408, 628237], 1024 * 1024 * 1024), '976128930.91';
    is download_rate([1638459407, 528237], [1638459407, 528237], 1024), undef;

    is download_speed([1638459407, 528237], [1638459408, 628237], 1024), '930.91 Byte/s';
    is download_speed([1638459407, 528237], [1638459408, 628237], 1024 * 1024), '931 KiB/s';
    is download_speed([1638459407, 528237], [1638459408, 628237], 1024 * 1024 * 1024), '931 MiB/s';
    is download_speed([1638459407, 528237], [1638459408, 628237], 1024 * 1024 * 1024 * 1024), '931 GiB/s';
    is download_speed([1638459407, 528237], [1638459408, 628237], 1024 * 1024 * 1024 * 1024 * 1024), '953251 GiB/s';

    is download_speed([1638459407, 528237], [1638459508, 628237], 1024 * 1024 * 512), '5.1 MiB/s';
    is download_speed([1638459407, 528237], [1638459407, 588237], 123456789), '1.9 GiB/s';

    is download_speed([1638459407, 528237], [1638459407, 528237], 1024), '??/s';
};

subtest 'labels' => sub {
    is_deeply find_labels(''), [], ' no labels found';
    is_deeply find_labels('label'), [], ' no labels found';
    is_deeply find_labels('label-123'), [], ' no labels found';
    is_deeply find_labels('test label:foo label:bar 123'), ['foo', 'bar'], 'labels found';
    is_deeply find_labels('test label:force_result:failed'), ['force_result:failed'], 'labels found';
    is_deeply find_labels('label:force_result:failed'), ['force_result:failed'], 'labels found';
    is_deeply find_labels('label:force_result:failed  test'), ['force_result:failed'], 'labels found';
    is_deeply find_labels('label label:foo:label label:bar 123'), ['foo:label', 'bar'], 'labels found';
    is_deeply find_labels('label label:foo:bnc#123 label:bar 123'), ['foo:bnc#123', 'bar'], 'labels found';
};

is bugurl('bsc#1234'), 'https://bugzilla.suse.com/show_bug.cgi?id=1234', 'bug url is properly expanded';
ok find_bugref('gh#os-autoinst/openQA#1234'), 'github bugref is recognized';
is(find_bugref('bsc#1234 poo#4321'), 'bsc#1234', 'first bugres found');
is_deeply(find_bugrefs('bsc#1234 poo#4321'), ['bsc#1234', 'poo#4321'], 'multiple bugrefs found');
is_deeply(find_bugrefs('bc#1234 #4321'), [], 'no bugrefs found');
is bugurl('gh#os-autoinst/openQA#1234'), 'https://github.com/os-autoinst/openQA/issues/1234';
is bugurl('poo#1234'), 'https://progress.opensuse.org/issues/1234';
is href_to_bugref('https://progress.opensuse.org/issues/1234'), 'poo#1234';
is bugref_to_href('boo#9876'), '<a href="https://bugzilla.opensuse.org/show_bug.cgi?id=9876">boo#9876</a>';
is href_to_bugref('https://github.com/foo/bar/issues/1234'), 'gh#foo/bar#1234';
is href_to_bugref('https://github.com/os-autoinst/os-autoinst/pull/960'), 'gh#os-autoinst/os-autoinst#960',
  'github pull are also transformed same as issues';
is bugref_to_href('gh#foo/bar#1234'), '<a href="https://github.com/foo/bar/issues/1234">gh#foo/bar#1234</a>';
like bugref_to_href('bsc#2345 poo#3456 and more'),
  qr{a href="https://bugzilla.suse.com/show_bug.cgi\?id=2345">bsc\#2345</a> <a href=.*3456.*> and more},
  'bugrefs in text get replaced';
like bugref_to_href('boo#2345,poo#3456'),
  qr{a href="https://bugzilla.opensuse.org/show_bug.cgi\?id=2345">boo\#2345</a>,<a href=.*3456.*},
  'interpunctation is not consumed by href';
is bugref_to_href('jsc#SLE-3275'), '<a href="https://jira.suse.de/browse/SLE-3275">jsc#SLE-3275</a>';
is href_to_bugref('https://jira.suse.de/browse/FOOBAR-1234'), 'jsc#FOOBAR-1234', 'jira tickets url to bugref';
is href_to_bugref('https://pagure.io/foo/issue/1234'), 'pio#foo#1234', 'pagure.io (no group) url to bugref';
is href_to_bugref('https://pagure.io/foo/bar/issue/1234'), 'pio#foo/bar#1234', 'pagure.io (with group) url to bugref';
is href_to_bugref('https://gitlab.gnome.org/GNOME/foo/-/issues/1234'), 'ggo#GNOME/foo#1234',
  'GNOME gitlab url to bugref';
is find_bug_number('yast_roleconf-ntp-servers-empty-bsc1114818-20181115.png'), 'bsc1114818',
  'find the bug number from the needle name';

my $t3 = {
    bar => {
        foo => 1,
        baz => [{fish => {boring => 'too'}}, {fish2 => {boring => 'not_really'}}]}};
walker(
    $t3 => sub {
        my ($k, $v, $ks, $what) = @_;
        next if reftype $what eq 'HASH' && exists $what->{_data};
        like $_[0], qr/bar|baz|foo|0|1|fish$|fish2|boring/, "Walked";

        $what->[$k] = {_type => ref $v, _data => $v} if reftype $what eq 'ARRAY';
        $what->{$k} = {_type => ref $v, _data => $v} if reftype $what eq 'HASH';

    });

is_deeply $t3,
  {
    'bar' => {
        '_data' => {
            'baz' => {
                '_data' => [
                    {
                        '_data' => {
                            'fish' => {
                                '_data' => {
                                    'boring' => {
                                        '_data' => 'too',
                                        '_type' => ''
                                    }
                                },
                                '_type' => 'HASH'
                            }
                        },
                        '_type' => 'HASH'
                    },
                    {
                        '_data' => {
                            'fish2' => {
                                '_data' => {
                                    'boring' => {
                                        '_data' => 'not_really',
                                        '_type' => ''
                                    }
                                },
                                '_type' => 'HASH'
                            }
                        },
                        '_type' => 'HASH'
                    }
                ],
                '_type' => 'ARRAY'
            },
            'foo' => {
                '_data' => 1,
                '_type' => ''
            }
        },
        '_type' => 'HASH'
    }};

subtest 'get current version' => sub {
    # Let's check that the version matches our versioning scheme.
    # If it's a git version it should be in the form: git-tag-sha1
    # otherwise is a group of 3 decimals followed by a partial sha1: a.b.c.sha1

    my $changelog_dir = tempdir;
    my $git_dir = tempdir;
    my $changelog_file = $changelog_dir->child('public')->make_path->child('Changelog');
    my $refs_file = $git_dir->child('.git')->make_path->child('packed-refs');
    my $head_file = $git_dir->child('.git', 'refs', 'heads')->make_path->child('master');
    my $sha_regex = qr/\b[0-9a-f]{5,40}\b/;

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

subtest 'Plugins handling' => sub {

    is path_to_class('foo/bar.pm'), "foo::bar";
    is path_to_class('foo/bar/baz.pm'), "foo::bar::baz";

    ok grep("OpenQA::Utils", loaded_modules), "Can detect loaded modules";
    ok grep("Test::Most", loaded_modules), "Can detect loaded modules";

    is_deeply [loaded_plugins('OpenQA::Utils', 'Test::Most')], ['OpenQA::Utils', 'Test::Most', 'Test::Most::Exception'],
      "Can detect loaded plugins, filtering by namespace";
    ok grep("Test::Most", loaded_plugins),
      "loaded_plugins() behave like loaded_modules() when no arguments are supplied";

    my $test_hash = {
        auth => {
            method => "Fake",
            foo => "bar",
            b => {bar2 => 2},
        },
        baz => {
            bar => "test"
        }};

    my %reconstructed_hash;
    hashwalker $test_hash => sub {
        my ($key, $value, $keys) = @_;

        my $r_hash = \%reconstructed_hash;
        for (my $i = 0; $i < scalar @$keys; $i++) {
            $r_hash->{$keys->[$i]} //= {};
            $r_hash = $r_hash->{$keys->[$i]} if $i < (scalar @$keys) - 1;
        }

        $r_hash->{$key} = $value if ref $r_hash eq 'HASH';

    };

    is_deeply \%reconstructed_hash, $test_hash, "hashwalker() reconstructed original hash correctly";
};

subtest asset_type_from_setting => sub {
    use OpenQA::Utils 'asset_type_from_setting';
    is asset_type_from_setting('ISO'), 'iso', 'simple from ISO';
    is asset_type_from_setting('UEFI_PFLASH_VARS'), 'hdd', "simple from UEFI_PFLASH_VARS";
    is asset_type_from_setting('UEFI_PFLASH_VARS', 'relative'), 'hdd', "relative from UEFI_PFLASH_VARS";
    is asset_type_from_setting('UEFI_PFLASH_VARS', '/absolute'), '', "absolute from UEFI_PFLASH_VARS";
};

subtest parse_assets_from_settings => sub {
    use OpenQA::Utils 'parse_assets_from_settings';
    my $settings = {
        ISO => "foo.iso",
        ISO_2 => "foo_2.iso",
        # this is a trap: shouldn't be treated as an asset
        HDD => "hdd.qcow2",
        HDD_1 => "hdd_1.qcow2",
        HDD_2 => "hdd_2.qcow2",
        # shouldn't be treated as asset *yet* as it's absolute
        UEFI_PFLASH_VARS => "/absolute/path/uefi_pflash_vars.qcow2",
        # trap
        REPO => "repo",
        REPO_1 => "repo_1",
        REPO_2 => "repo_2",
        # trap
        ASSET => "asset.pm",
        ASSET_1 => "asset_1.pm",
        ASSET_2 => "asset_2.pm",
        KERNEL => "vmlinuz",
        INITRD => "initrd.img",
    };
    my $assets = parse_assets_from_settings($settings);
    my $refassets = {
        ISO => {type => "iso", name => "foo.iso"},
        ISO_2 => {type => "iso", name => "foo_2.iso"},
        HDD_1 => {type => "hdd", name => "hdd_1.qcow2"},
        HDD_2 => {type => "hdd", name => "hdd_2.qcow2"},
        REPO_1 => {type => "repo", name => "repo_1"},
        REPO_2 => {type => "repo", name => "repo_2"},
        ASSET_1 => {type => "other", name => "asset_1.pm"},
        ASSET_2 => {type => "other", name => "asset_2.pm"},
        KERNEL => {type => "other", name => "vmlinuz"},
        INITRD => {type => "other", name => "initrd.img"},
    };
    is_deeply $assets, $refassets, "correct with absolute UEFI_PFLASH_VARS";
    # now make this relative: it should now be seen as an asset type
    $settings->{UEFI_PFLASH_VARS} = "uefi_pflash_vars.qcow2";
    $assets = parse_assets_from_settings($settings);
    $refassets->{UEFI_PFLASH_VARS} = {type => "hdd", name => "uefi_pflash_vars.qcow2"};
    is_deeply $assets, $refassets, "correct with relative UEFI_PFLASH_VARS";
};

subtest 'base_host' => sub {
    is base_host('http://opensuse.org'), 'opensuse.org';
    is base_host('www.opensuse.org'), 'www.opensuse.org';
    is base_host('test'), 'test';
    is base_host('https://opensuse.org/test/1/2/3'), 'opensuse.org';
};

subtest 'project directory functions' => sub {
    my $distri = 'opensuse';
    subtest 'default OPENQA_BASEDIR/OPENQA_SHAREDIR' => sub {
        local $ENV{OPENQA_BASEDIR};
        local $ENV{OPENQA_SHAREDIR};
        is prjdir, '/var/lib/openqa', 'prjdir';
        is sharedir, '/var/lib/openqa/share', 'sharedir';
        is resultdir, '/var/lib/openqa/testresults', 'resultdir';
        is assetdir, '/var/lib/openqa/share/factory', 'assetdir';
        is imagesdir, '/var/lib/openqa/images', 'imagesdir';
        is gitrepodir, '', 'no gitrepodir when distri is not defined';
    };
    subtest 'custom OPENQA_BASEDIR' => sub {
        local $ENV{OPENQA_BASEDIR} = '/tmp/test';
        is prjdir, '/tmp/test/openqa', 'prjdir';
        is sharedir, '/tmp/test/openqa/share', 'sharedir';
        is resultdir, '/tmp/test/openqa/testresults', 'resultdir';
        is assetdir, '/tmp/test/openqa/share/factory', 'assetdir';
        is imagesdir, '/tmp/test/openqa/images', 'imagesdir';
        my $mocked_git = path(sharedir . '/tests/opensuse/.git');
        $mocked_git->remove_tree if -e $mocked_git;
        is gitrepodir(distri => $distri), '', 'empty when .git is missing';
        $mocked_git->make_path;
        $mocked_git->child('config')
          ->spurt(qq{[remote "origin"]\n        url = git\@github.com:fakerepo/os-autoinst-distri-opensuse.git});
        is gitrepodir(distri => $distri) =~ /github\.com.+os-autoinst-distri-opensuse\/commit/, 1, 'correct git url';
        $mocked_git->child('config')
          ->spurt(qq{[remote "origin"]\n        url = https://github.com/fakerepo/os-autoinst-distri-opensuse.git});
        is gitrepodir(distri => $distri) =~ /github\.com.+os-autoinst-distri-opensuse\/commit/, 1, 'correct git url';
    };
    subtest 'custom OPENQA_BASEDIR and OPENQA_SHAREDIR' => sub {
        local $ENV{OPENQA_BASEDIR} = '/tmp/test';
        local $ENV{OPENQA_SHAREDIR} = '/tmp/share';
        is prjdir, '/tmp/test/openqa', 'prjdir';
        is sharedir, '/tmp/share', 'sharedir';
        is resultdir, '/tmp/test/openqa/testresults', 'resultdir';
        is assetdir, '/tmp/share/factory', 'assetdir';
        is imagesdir, '/tmp/test/openqa/images', 'imagesdir';
        is gitrepodir, '', 'no gitrepodir when distri is not defined';
        is gitrepodir(distri => $distri) =~ /github\.com.+os-autoinst-distri-opensuse\/commit/, 1, 'correct git url';
    };
};

subtest 'change_sec_to_word' => sub {
    is change_sec_to_word(), undef, 'do pass parameter';
    is change_sec_to_word(1.2), undef, 'treat float as invalid parameter';
    is change_sec_to_word('test'), undef, 'treat string as invalid parameter';
    is change_sec_to_word(10), '10s', 'correctly converted (seconds)';
    is change_sec_to_word(70), '1m 10s', 'correctly converted (minutes + seconds)';
    is change_sec_to_word(900), '15m', 'correctly converted (minutes)';
    is change_sec_to_word(3900), '1h 5m', 'correctly converted (hours + minutes)';
    is change_sec_to_word(7201), '2h 1s', 'correctly converted (hours + seconds)';
    is change_sec_to_word(64890), '18h 1m 30s', 'correctly converted (hours + minutes + seconds)';
    is change_sec_to_word(648906), '7d 12h 15m 6s', 'correctly converted (all units)';
};

subtest 'usleep_backoff' => sub {
    subtest 'with fixed padding to test exact behavior' => sub {
        is usleep_backoff(1, 5, 30, 1_000_001), 6_000_001, 'delay one';
        is usleep_backoff(2, 5, 30, 1_000_001), 7_000_001, 'delay two';
        is usleep_backoff(3, 5, 30, 1_000_001), 8_000_001, 'delay three';
        is usleep_backoff(4, 5, 30, 1_000_001), 9_000_001, 'delay four';
        is usleep_backoff(5, 5, 30, 1_000_001), 10_000_001, 'delay five';
        is usleep_backoff(6, 5, 30, 1_000_001), 11_000_001, 'delay six';
        is usleep_backoff(7, 5, 30, 1_000_001), 12_000_001, 'delay seven';
        is usleep_backoff(8, 5, 30, 1_000_001), 13_000_001, 'delay eight';
        is usleep_backoff(9, 5, 30, 1_000_001), 14_000_001, 'delay nine';
        is usleep_backoff(10, 5, 30, 1_000_001), 15_000_001, 'delay ten';
    };

    subtest 'with random 1 second default padding' => sub {
        my $real_usleep_value = usleep_backoff(3, 5, 30);
        ok $real_usleep_value <= 8_000_000, 'less than 8 seconds';
        ok $real_usleep_value > 7_000_000, 'more than 7 seconds';
    };

    subtest 'disabled with 0 second minimum value' => sub {
        is usleep_backoff(5, 0, 30), 0, 'default to 0 if allowed';
    };

    subtest 'special cases' => sub {
        is usleep_backoff(5, 40, 30), 30_000_000, 'maximum is not exceeded even if the minimum is higher';
    };
};

my ($current_term_handler, $current_int_handler) = ($SIG{TERM}, $SIG{INT});
subtest 'signal handling in Minion jobs' => sub {
    my $job = Test::MockObject->new;
    my $signal_guard = OpenQA::Task::SignalGuard->new($job);
    $job->set_true($_) for qw(retry finish note);

    subtest 'signal arrives after lock acquisition' => sub {
        is exit_code { kill INT => $$ }, 0, 'exited when signal arrives after lock acquisition';
        $job->called_ok('note');
        $job->called_ok('retry');
        $job->called_args_pos_is(0, 3, 'Received signal INT, scheduling retry and releasing locks');
        $job->clear;
    };
    subtest 'signal arrives after retry disabled' => sub {
        $signal_guard->retry(0);
        is exit_code { kill INT => $$ }, undef, 'not exited (the job is supposed to be concluded at this point)';
        $job->called_ok('note');
        $job->called_args_pos_is(0, 3, 'Received signal INT, concluding');
        ok !$job->called('retry'), 'job not retried';
        $job->clear;
    };
    subtest 'signal arrives after abort-flag set' => sub {
        $signal_guard->abort(1);
        is exit_code { kill INT => $$ }, 0, 'exited when signal arrives after abort-flag set';
        $job->called_ok('note');
        $job->called_args_pos_is(0, 3, 'Received signal INT, aborting');
        ok !$job->called('retry'), 'job not retried';
        ok $job->called('finish'), 'job considered finished';
    };
};
is $SIG{TERM}, $current_term_handler, 'SIGTERM handler restored after signal guard goes out of scope';
is $SIG{INT}, $current_int_handler, 'SIGINT handler restored after signal guard goes out of scope';

done_testing;
