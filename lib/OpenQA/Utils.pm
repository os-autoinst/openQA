# Copyright 2012-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Utils;

use strict;
use warnings;

use Mojo::Base -signatures;
use Carp;
use Cwd 'abs_path';
use Filesys::Df qw(df);
use IPC::Run();
use Mojo::URL;
use Regexp::Common 'URI';
use Time::Seconds;
use Try::Tiny;
use Mojo::File 'path';
use IO::Handle;
use IO::Socket::IP;
use POSIX 'strftime';
use Scalar::Util 'blessed';
use Mojo::Log;
use Scalar::Util qw(blessed reftype looks_like_number);
use Exporter 'import';
use OpenQA::App;
use OpenQA::Constants qw(VIDEO_FILE_NAME_START VIDEO_FILE_NAME_REGEX FRAGMENT_REGEX);
use OpenQA::Log qw(log_info log_debug log_warning log_error);

# avoid boilerplate "$VAR1 = " in dumper output
$Data::Dumper::Terse = 1;

my $FRAG_REGEX = FRAGMENT_REGEX;

our $VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
our @EXPORT = qw(
  locate_needle
  needledir
  productdir
  testcasedir
  is_in_tests
  save_base64_png
  run_cmd_with_log
  run_cmd_with_log_return_error
  parse_assets_from_settings
  find_bugref
  find_bugrefs
  bugref_regex
  bugurl
  bugref_to_href
  href_to_bugref
  url_to_href
  find_bug_number
  render_escaped_refs
  asset_type_from_setting
  check_download_url
  check_download_passlist
  get_url_short
  create_downloads_list
  human_readable_size
  locate_asset
  detect_current_version
  parse_tags_from_comments
  path_to_class
  loaded_modules
  loaded_plugins
  hashwalker
  read_test_modules
  feature_scaling
  logistic_map_steps
  logistic_map
  rand_range
  in_range
  walker
  ensure_timestamp_appended
  set_listen_address
  service_port
  change_sec_to_word
  find_video_files
  fix_top_level_help
  looks_like_url_with_scheme
  check_df
);

our @EXPORT_OK = qw(
  prjdir
  sharedir
  archivedir
  resultdir
  assetdir
  imagesdir
  base_host
  determine_web_ui_web_socket_url
  get_ws_status_only_url
  random_string
  random_hex
);

# override OPENQA_BASEDIR for tests
if ($0 =~ /\.t$/) {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    $ENV{OPENQA_BASEDIR} ||= $tdirname . 'data';
}

use File::Basename;
use File::Spec;
use File::Spec::Functions qw(catfile catdir);
use Fcntl;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Util 'xml_escape';

sub prjdir { ($ENV{OPENQA_BASEDIR} || '/var/lib') . '/openqa' }

sub sharedir { $ENV{OPENQA_SHAREDIR} || (prjdir() . '/share') }

sub archivedir { $ENV{OPENQA_ARCHIVEDIR} || (prjdir() . '/archive') }

sub resultdir ($archived = 0) { ($archived ? archivedir() : prjdir()) . '/testresults' }

sub assetdir { sharedir() . '/factory' }

sub imagesdir { prjdir() . '/images' }

# the desired new folder structure is
# $testcasedir/<testrepository>
# with "main.pm" and needles being in a productdir under <testrepository>
# defined by $distri forming the full path of
#  $testcasedir/<testrepository>/products/$distri
# with a fallback to searching for the main.pm in the <testrepository> top
# folder. <testrepository> is formed by $distri and $version with path lookup
# but could later on also be defined with a variable if necessary.
# To be backwards compatible we need to search for all combinations of "old/new
# testrepository name" and "old/new folder structure" within the
# testrepository.
sub productdir {
    my ($distri, $version, $rootfortests) = @_;

    my $dir = testcasedir($distri, $version, $rootfortests);
    return "$dir/products/$distri" if $distri && -e "$dir/products/$distri";
    return $dir;
}

sub testcasedir {
    my ($distri, $version, $rootfortests) = @_;
    my $prjdir = prjdir();
    for my $dir (catdir($prjdir, 'share', 'tests'), catdir($prjdir, 'tests')) {
        $rootfortests ||= $dir if -d $dir;
    }
    $distri //= '';
    # TODO actually "distri" is misused here. It should rather be something
    # like the name of the repository with all tests
    my $dir = catdir($rootfortests, $distri);
    $dir .= "-$version" if $version && -e "$dir-$version";
    return $dir;
}

sub is_in_tests {
    my ($file) = @_;

    $file = File::Spec->rel2abs($file);
    # at least tests use a relative $prjdir, so it needs to be converted to absolute path as well
    my $abs_projdir = File::Spec->rel2abs(prjdir());
    return index($file, catdir($abs_projdir, 'share', 'tests')) == 0
      || index($file, catdir($abs_projdir, 'tests')) == 0;
}

sub needledir { productdir(@_) . '/needles' }

sub locate_needle {
    my ($relative_needle_path, $needles_dir) = @_;

    my $absolute_filename = catdir($needles_dir, $relative_needle_path);
    my $needle_exists = -f $absolute_filename;

    if (!$needle_exists) {
        $absolute_filename = catdir(sharedir(), $relative_needle_path);
        $needle_exists = -f $absolute_filename;
    }
    return $absolute_filename if $needle_exists;

    log_error("Needle file $relative_needle_path not found within $needles_dir.");
    return undef;
}

# Adds a timestamp to a string (eg. needle name) or replace the already present timestamp
sub ensure_timestamp_appended {
    my ($str) = @_;

    my $today = strftime('%Y%m%d', gmtime(time));
    if ($str =~ /(.*)-\d{8}$/) {
        return "$1-$today";
    }
    return "$str-$today";
}

sub save_base64_png {
    my ($dir, $newfile, $png) = @_;
    return unless $newfile;
    # sanitize
    $newfile =~ s,\.png,,;
    $newfile =~ tr/a-zA-Z0-9-/_/cs;
    open(my $fh, ">", $dir . "/$newfile.png") || die "can't open $dir/$newfile.png: $!";
    use MIME::Base64 'decode_base64';
    $fh->print(decode_base64($png));
    close($fh);
    return $newfile;
}

sub image_md5_filename {
    my ($md5, $onlysuffix) = @_;

    my $prefix1 = substr($md5, 0, 3);
    $md5 = substr($md5, 3);
    my $prefix2 = substr($md5, 0, 3);
    $md5 = substr($md5, 3);

    if ($onlysuffix) {
        # stored this way in the database
        return catfile($prefix1, $prefix2, "$md5.png");
    }

    my $imagesdir = imagesdir();
    return (
        catfile($imagesdir, $prefix1, $prefix2, "$md5.png"),
        catfile($imagesdir, $prefix1, $prefix2, '.thumbs', "$md5.png"));
}

# returns the url to the web socket proxy started via openqa-livehandler
sub determine_web_ui_web_socket_url {
    my ($job_id) = @_;
    return "liveviewhandler/tests/$job_id/developer/ws-proxy";
}

# returns the url for the status route over websocket proxy via openqa-livehandler
sub get_ws_status_only_url {
    my ($job_id) = @_;
    return "liveviewhandler/tests/$job_id/developer/ws-proxy/status";
}

sub run_cmd_with_log {
    my ($cmd) = @_;
    return run_cmd_with_log_return_error($cmd)->{status};
}

sub run_cmd_with_log_return_error {
    my ($cmd) = @_;

    log_info('Running cmd: ' . join(' ', @$cmd));
    try {
        my ($stdin, $stdout_err);
        my $ipc_run_succeeded = IPC::Run::run($cmd, \$stdin, '>&', \$stdout_err);
        my $return_code = $?;
        chomp $stdout_err;
        if ($ipc_run_succeeded) {
            log_debug($stdout_err);
            log_info("cmd returned $return_code");
        }
        else {
            log_warning($stdout_err);
            log_error("cmd returned $return_code");
        }
        return {
            status => $ipc_run_succeeded,
            return_code => $return_code,
            stderr => $stdout_err,
        };
    }
    catch {
        return {
            status => 0,
            return_code => undef,
            stderr => "an internal error occurred",
        };
    };
}

sub asset_type_from_setting {
    # passing $value is optional but makes the result more accurate
    # (it affects only UEFI_PFLASH_VARS currently).
    my ($setting, $value) = @_;
    $value //= '';
    if ($setting eq 'ISO' || $setting =~ /^ISO_\d+$/) {
        return 'iso';
    }
    if ($setting =~ /^HDD_\d+$/) {
        return 'hdd';
    }
    # non-absolute-path value of UEFI_PFLASH_VARS treated as HDD asset
    if ($setting eq 'UEFI_PFLASH_VARS' && $value !~ m,^/,) {
        return 'hdd';
    }
    if ($setting =~ /^REPO_\d+$/) {
        return 'repo';
    }
    if ($setting =~ /^ASSET_\d+$/ || $setting eq 'KERNEL' || $setting eq 'INITRD') {
        return 'other';
    }
    # empty string if this doesn't look like an asset type
    return '';
}

sub parse_assets_from_settings {
    my ($settings) = (@_);
    my $assets = {};

    for my $k (keys %$settings) {
        my $type = asset_type_from_setting($k, $settings->{$k});
        if ($type) {
            $assets->{$k} = {type => $type, name => $settings->{$k}};
        }
    }

    return $assets;
}

sub _relative_or_absolute {
    my ($path, $relative) = @_;

    return $path if $relative;
    return catfile(assetdir(), $path);
}

# find the actual disk location of a given asset. Supported arguments are
# mustexist => 1 - return undef if the asset is not present
# relative => 1 - return path below assetdir, otherwise absolute path
sub locate_asset {
    my ($type, $name, %args) = @_;

    my $trans = catfile($type, $name);
    return _relative_or_absolute($trans, $args{relative}) if -e _relative_or_absolute($trans);

    my $fixed = catfile($type, 'fixed', $name);
    return _relative_or_absolute($fixed, $args{relative}) if -e _relative_or_absolute($fixed);

    return $args{mustexist} ? undef : _relative_or_absolute($trans, $args{relative});
}

my %bugrefs = (
    bnc => 'https://bugzilla.suse.com/show_bug.cgi?id=',
    bsc => 'https://bugzilla.suse.com/show_bug.cgi?id=',
    boo => 'https://bugzilla.opensuse.org/show_bug.cgi?id=',
    bgo => 'https://bugzilla.gnome.org/show_bug.cgi?id=',
    brc => 'https://bugzilla.redhat.com/show_bug.cgi?id=',
    bko => 'https://bugzilla.kernel.org/show_bug.cgi?id=',
    poo => 'https://progress.opensuse.org/issues/',
    gh => 'https://github.com/',
    kde => 'https://bugs.kde.org/show_bug.cgi?id=',
    fdo => 'https://bugs.freedesktop.org/show_bug.cgi?id=',
    jsc => 'https://jira.suse.de/browse/',
);
my %bugurls = (
    'https://bugzilla.novell.com/show_bug.cgi?id=' => 'bsc',
    $bugrefs{bsc} => 'bsc',
    $bugrefs{boo} => 'boo',
    $bugrefs{bgo} => 'bgo',
    $bugrefs{brc} => 'brc',
    $bugrefs{bko} => 'bko',
    $bugrefs{poo} => 'poo',
    $bugrefs{gh} => 'gh',
    $bugrefs{kde} => 'kde',
    $bugrefs{fdo} => 'fdo',
    $bugrefs{jsc} => 'jsc',
);

my $MARKER_REFS = join('|', keys %bugrefs);
my $MARKER_URLS = join('|', keys %bugurls);

sub bugref_regex {
    my $repo_re = qr{[a-zA-Z/-]+};
    # <marker>[#<project/repo>]#<id>
    return qr{(?<![\(\[\"\>])(?<match>(?<marker>$MARKER_REFS)\#?(?<repo>$repo_re)?\#(?<id>([A-Z]+-)?\d+))(?![\w\"])};
}

sub find_bugref {
    my ($text) = @_;
    $text //= '';
    $text =~ bugref_regex;
    return $+{match};
}

sub find_bugrefs {
    my ($text) = @_;
    $text //= '';
    my @bugrefs;
    my $bugref_regex = bugref_regex;

    while ($text =~ /$bugref_regex/g) {
        push(@bugrefs, $+{match});
    }
    return \@bugrefs;
}

sub bugurl {
    my ($bugref) = @_;
    # in github '/pull/' and '/issues/' are interchangeable, e.g.
    # calling https://github.com/os-autoinst/openQA/issues/966 will yield the
    # same page as https://github.com/os-autoinst/openQA/pull/966 and vice
    # versa for both an issue as well as pull request
    $bugref =~ bugref_regex;
    return $bugrefs{$+{marker}} . ($+{repo} ? "$+{repo}/issues/" : '') . $+{id};
}

sub bugref_to_href {
    my ($text) = @_;
    my $regex = bugref_regex;
    $text =~ s{$regex}{<a href="@{[bugurl($+{match})]}">$+{match}</a>}gi;
    return $text;
}

sub href_to_bugref {
    my ($text) = @_;
    my $regex = $MARKER_URLS =~ s/\?/\\\?/gr;
    # <repo> is optional, e.g. for github. For github issues and pull are
    # interchangeable, see comment in 'bugurl', too
    $regex = qr{(?<!["\(\[])(?<url_root>$regex)((?<repo>.*)/(issues|pull)/)?(?<id>([A-Z]+-)?\d+)(?![\w])};
    $text =~ s{$regex}{@{[$bugurls{$+{url_root}} . ($+{repo} ? '#' . $+{repo} : '')]}#$+{id}}gi;
    return $text;
}

sub url_to_href {
    my ($text) = @_;
    $text =~ s!($RE{URI}$FRAG_REGEX)!<a href="$1">$1</a>!gx;
    return $text;
}

sub render_escaped_refs {
    my ($text) = @_;
    return bugref_to_href(url_to_href(xml_escape($text)));
}

sub find_bug_number {
    my ($text) = @_;
    return $text =~ /\S+\-((?:$MARKER_REFS)\d+)\-\S+/ ? $1 : undef;
}

sub check_download_url {
    # Passed a URL and the download_domains passlist from openqa.ini.
    # Checks if the host of the URL is in the passlist. Returns an
    # array: (1, host) if there is a passlist and the host is not in
    # it, (2, host) if there is no passlist, and () if we pass. This
    # is used by check_download_passlist below (and so indirectly by
    # the Iso controller) and directly by the download_asset() Gru
    # task subroutine.
    my ($url, $passlist) = @_;
    my @okdomains;
    if (defined $passlist) {
        @okdomains = split(/ /, $passlist);
    }
    my $host = Mojo::URL->new($url)->host;
    unless (@okdomains) {
        return (2, $host);
    }
    my $ok = 0;
    for my $okdomain (@okdomains) {
        my $quoted = qr/$okdomain/;
        $ok = 1 if ($host =~ /${quoted}$/);
    }
    if ($ok) {
        return ();
    }
    else {
        return (1, $host);
    }
}

sub check_download_passlist {
    # Passed the params hash ref for a job and the download_domains
    # passlist read from openqa.ini. Checks that all params ending
    # in _URL (i.e. requesting asset download) specify URLs that are
    # passlisted. It's provided here so that we can run the check
    # twice, once to return immediately and conveniently from the Iso
    # controller, once again directly in the Gru asset download sub
    # just in case someone somehow manages to bypass the API and
    # create a gru task directly. On failure, returns an array of 4
    # items: the first is 1 if there was a passlist at all or 2 if
    # there was not, the second is the name of the param for which the
    # check failed, the third is the URL, and the fourth is the host.
    # On success, returns an empty array.

    my ($params, $passlist) = @_;
    my @okdomains;
    if (defined $passlist) {
        @okdomains = split(/ /, $passlist);
    }
    for my $param (keys %$params) {
        next unless ($param =~ /_URL$/);
        my $url = $$params{$param};
        my @check = check_download_url($url, $passlist);
        next unless (@check);
        # if we get here, we got a failure
        return ($check[0], $param, $url, $check[1]);
    }
    # empty list signals caller that check passed
    return ();
}

sub get_url_short {
    # Given a setting name, if it ends with _URL or _DECOMPRESS_URL
    # return the name with that string stripped, and a flag indicating
    # whether decompression will be needed. If it doesn't, returns
    # empty string and 0.
    my ($arg) = @_;
    return ('', 0) unless ($arg =~ /_URL$/);
    my $short;
    my $do_extract = 0;
    if ($arg =~ /_DECOMPRESS_URL$/) {
        $short = substr($arg, 0, -15);
        $do_extract = 1;
    }
    else {
        $short = substr($arg, 0, -4);
    }
    return ($short, $do_extract);
}

sub create_downloads_list {
    my ($args) = @_;
    my %downloads = ();
    for my $arg (keys %$args) {
        my $url = $args->{$arg};
        my ($short, $do_extract) = get_url_short($arg);
        next unless ($short);
        my $filename = $args->{$short};
        unless ($filename) {
            log_debug("No target filename set for $url. Ignoring $arg");
            next;
        }
        # We're only going to allow downloading of asset types. We also
        # need this to determine the download location later
        my $assettype = asset_type_from_setting($short, $args->{$short});
        unless ($assettype) {
            log_debug("_URL downloading only allowed for asset types! $short is not an asset type");
            next;
        }
        # Find where we should download the file to
        my $fullpath = locate_asset($assettype, $filename, mustexist => 0);

        unless (-s $fullpath) {
            # if the file doesn't exist, add the url/target path and extraction
            # flag as a key/value pair to the %downloads hash
            $downloads{$url} = [$fullpath, $do_extract];
        }
    }
    return \%downloads;
}

sub _round_a_bit {
    my ($size) = @_;

    if ($size < 10) {
        # give it one digit
        return int($size * 10 + .5) / 10.;
    }

    return int($size + .5);
}

sub human_readable_size {
    my ($size) = @_;

    my $p = ($size < 0) ? '-' : '';
    $size = abs($size);
    if ($size < 3000) {
        return "$p$size Byte";
    }
    $size = $size / 1024.;
    if ($size < 1024) {
        return $p . _round_a_bit($size) . " KiB";
    }

    $size /= 1024.;
    if ($size < 1024) {
        return $p . _round_a_bit($size) . " MiB";
    }

    $size /= 1024.;
    return $p . _round_a_bit($size) . " GiB";
}

sub read_test_modules {
    my ($job) = @_;

    my $testresultdir = $job->result_dir();
    return unless $testresultdir;

    my $category;
    my $has_parser_text_results = 0;
    my @modlist;

    for my $module ($job->modules_with_job_prefetched->all) {
        my $name = $module->name();
        # add link to $testresultdir/$name*.png via png CGI
        my @details;

        my $num = 1;
        my $has_module_parser_text_result = 0;

        my $module_results = $module->results;
        for my $step (@{$module_results->{details}}) {
            my $text = $step->{text};
            my $source = $step->{_source};

            $step->{num} = $num++;
            $step->{display_title} = ($text ? $step->{title} : $step->{name}) // '';
            $step->{is_parser_text_result} = 0;
            if ($source && $source eq 'parser' && $text && $step->{text_data}) {
                $step->{is_parser_text_result} = 1;
                $has_module_parser_text_result = 1;
            }

            $step->{resborder} = 'resborder_' . (($step->{result} && !(ref $step->{result})) ? $step->{result} : 'unk');

            push(@details, $step);
        }

        $has_parser_text_results = 1 if ($has_module_parser_text_result);

        push(
            @modlist,
            {
                name => $module->name,
                result => $module->result,
                details => \@details,
                milestone => $module->milestone,
                important => $module->important,
                fatal => $module->fatal,
                always_rollback => $module->always_rollback,
                has_parser_text_result => $has_module_parser_text_result,
                execution_time => change_sec_to_word($module_results->{execution_time}),
            });

        if (!$category || $category ne $module->category) {
            $category = $module->category;
            $modlist[-1]->{category} = $category;
        }

    }

    return {
        modules => \@modlist,
        has_parser_text_results => $has_parser_text_results,
    };
}

# parse comments of the specified (parent) group and store all mentioned builds in $res (hashref)
sub parse_tags_from_comments {
    my ($group, $res) = @_;

    my $comments = $group->comments;
    return unless ($comments);

    while (my $comment = $comments->next) {
        my @tag = $comment->tag;
        my $build = $tag[0];
        next unless $build;

        my $version = $tag[3];
        my $tag_id = $version ? "$version-$build" : $build;

        log_debug('Tag found on build ' . $build . ' of type ' . $tag[1]);
        log_debug('description: ' . $tag[2]) if $tag[2];
        if ($tag[1] eq '-important') {
            log_debug('Deleting tag on build ' . $build);
            delete $res->{$tag_id};
            next;
        }

        # ignore tags on non-existing builds
        $res->{$tag_id} = {build => $build, type => $tag[1], description => $tag[2], version => $version};
    }
}

sub detect_current_version {
    my ($path) = @_;

    # Get application version
    my $current_version = undef;
    my $changelog_file = path($path, 'public', 'Changelog');
    my $head_file = path($path, '.git', 'refs', 'heads', 'master');
    my $refs_file = path($path, '.git', 'packed-refs');

    if (-e $changelog_file) {
        my $changelog = $changelog_file->slurp;
        if ($changelog && $changelog =~ /Update to version (\d+\.\d+\.\d+\.(\b[0-9a-f]{5,40}\b))\:/mi) {
            $current_version = $1;
        }
    }
    elsif (-e $head_file && -e $refs_file) {
        my $master_head = $head_file->slurp;
        my $packed_refs = $refs_file->slurp;

        # Extrapolate latest tagged version and combine it
        # with latest commit which heads is pointed to.
        # This method have its limits while checking out different branches
        # but emulates git-describe output without executing commands.
        if ($master_head && $packed_refs) {
            my $latest_ref = (grep(/tags/, split(/\s/, $packed_refs)))[-1];
            my $partial_hash = substr($master_head, 0, 8);
            if ($latest_ref && $partial_hash) {
                my $tag = (split(/\//, $latest_ref))[-1];
                $current_version = $tag ? "git-" . $tag . "-" . $partial_hash : undef;
            }
        }
    }
    return $current_version;
}

# Resolves a path to class
# path is expected to be in the form of the keys of %INC. e.g. : foo/bar/baz.pm
sub path_to_class { substr join('::', split(/\//, shift)), 0, -3 }

# Returns all modules that are loaded into memory
sub loaded_modules {
    map { path_to_class($_); } sort keys %INC;
}

# Fallback to loaded_modules if no arguments are given.
# Accepts namespaces as arguments. If supplied, it will filter by them
sub loaded_plugins {
    my $ns = join("|", map { quotemeta } @_);
    return @_ ? grep { /^$ns/ } loaded_modules() : loaded_modules();
}

# Walks a hash keeping keys as a stack
sub hashwalker {
    my ($hash, $callback, $keys) = @_;
    $keys = [] if !$keys;
    foreach my $key (sort keys %$hash) {
        my $value = $hash->{$key};
        push @$keys, $key;
        if (ref($value) eq 'HASH') {
            hashwalker($value, $callback, $keys);
        }
        else {
            $callback->($key, $value, $keys);
        }
        pop @$keys;
    }
}

# Walks whatever
sub walker {
    my ($hash, $callback, $keys) = @_;
    $keys //= [];
    if (reftype $hash eq 'HASH') {
        foreach my $key (sort keys %$hash) {
            push @$keys, [reftype($hash), $key];
            my $k_ref = reftype $hash->{$key};
            if ($k_ref && $k_ref eq 'HASH') {
                walker($hash->{$key}, $callback, $keys);
                $callback->($key, $hash->{$key}, $keys, $hash);
            }
            elsif ($k_ref && $k_ref eq 'ARRAY') {
                walker($hash->{$key}, $callback, $keys);
                $callback->($key, $hash->{$key}, $keys, $hash);
            }
            else {
                $callback->($key, $hash->{$key}, $keys, $hash);
            }
            pop @$keys;
        }
    }
    elsif (reftype $hash eq 'ARRAY') {
        my $i = 0;
        for my $elem (@{$hash}) {
            push @$keys, [reftype($hash), $i];
            my $el_ref = reftype $elem;
            if ($el_ref && $el_ref eq 'ARRAY') {
                walker($elem, $callback, $keys);
                $callback->($i, $elem, $keys, $hash);
            }
            elsif ($el_ref && $el_ref eq 'HASH') {
                walker($elem, $callback, $keys);
                $callback->($i, $elem, $keys, $hash);
            }

            $i++;
            pop @$keys;
        }
    }
}


# Args:
# First is i-th element, Second is maximum element number, Third and Fourth are the range limit (lower and upper)
# $i, $imax, MIN, MAX
sub feature_scaling { $_[2] + ((($_[0] - 1) * ($_[3] - $_[2])) / (($_[1] - 1) || 1)) }
# $r, $xn
sub logistic_map { $_[0] * $_[1] * (1 - $_[1]) }
# $steps, $r, $xn
sub logistic_map_steps {
    $_[2] = 0.1 if $_[2] <= 0;    # do not let population die. - with this change we get more "chaos"
    $_[2] = logistic_map($_[1], $_[2]) for (1 .. $_[0]);
    $_[2];
}
sub rand_range { $_[0] + rand($_[1] - $_[0]) }
sub in_range { $_[0] >= $_[1] && $_[0] <= $_[2] ? 1 : 0 }

sub set_listen_address {
    my $port = shift;

    return if $ENV{MOJO_LISTEN};
    my @listen_addresses = ("http://127.0.0.1:$port");

    # Check for IPv6
    push @listen_addresses, "http://[::1]:$port" if IO::Socket::IP->new(Listen => 5, LocalAddr => '::1');

    $ENV{MOJO_LISTEN} = join ',', @listen_addresses;
}

sub service_port {
    my $service = shift;

    my $base = $ENV{OPENQA_BASE_PORT} ||= 9526;

    my $offsets = {
        webui => 0,
        websocket => 1,
        livehandler => 2,
        scheduler => 3,
        cache_service => 4
    };
    croak "Unknown service: $service" unless exists $offsets->{$service};
    return $base + $offsets->{$service};
}

sub random_string {
    my ($length, $chars) = @_;
    $length //= 16;
    $chars //= ['a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'];
    return join('', map { $chars->[rand @$chars] } 1 .. $length);
}

sub random_hex {
    my ($length) = @_;
    $length //= 16;
    my $toread = $length / 2 + $length % 2;
    # uncoverable branch true
    open(my $fd, '<:raw:bytes', '/dev/urandom') || croak "can't open /dev/urandom: $!";
    # uncoverable branch true
    read($fd, my $bytes, $toread) || croak "can't read random byte: $!";
    close $fd;
    return uc substr(unpack('H*', $bytes), 0, $length);
}

sub any_array_item_contained_by_hash {
    my ($array, $hash) = @_;

    for my $array_item (@$array) {
        return 1 if ($hash->{$array_item});
    }
    return 0;
}

sub base_host { Mojo::URL->new($_[0])->host || $_[0] }

sub change_sec_to_word {
    my ($second) = @_;
    return undef unless ($second);
    return undef if ($second !~ /^[[:digit:]]+$/);
    my %time_numbers = (
        d => ONE_DAY,
        h => ONE_HOUR,
        m => ONE_MINUTE,
        s => 1
    );
    my $time_word = '';
    for my $key (qw(d h m s)) {
        $time_word = $time_word . int($second / $time_numbers{$key}) . $key . ' '
          if (int($second / $time_numbers{$key}));
        $second = int($second % $time_numbers{$key});
    }
    $time_word =~ s/\s$//g;
    return $time_word;
}

sub find_video_files { path(shift)->list_tree->grep(VIDEO_FILE_NAME_REGEX) }

# workaround https://github.com/mojolicious/mojo/issues/1629
sub fix_top_level_help { @ARGV = () if ($ARGV[0] // '') =~ qr/^(-h|(--)?help)$/ }

sub looks_like_url_with_scheme { return !!Mojo::URL->new(shift)->scheme }

sub check_df ($dir) {
    my $df = Filesys::Df::df($dir, 1) // {};
    my $available_bytes = $df->{bavail};
    my $total_bytes = $df->{blocks};
    die "Unable to determine disk usage of '$dir'"
      unless looks_like_number($available_bytes)
      && looks_like_number($total_bytes)
      && $total_bytes > 0
      && $available_bytes >= 0
      && $available_bytes <= $total_bytes;
    return ($available_bytes, $total_bytes);
}

1;
