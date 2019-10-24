# Copyright (C) 2012-2019 SUSE LLC
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
# You should have received a copy of the GNU General Public License

package OpenQA::Utils;

use strict;
use warnings;

use Carp;
use Cwd 'abs_path';
use IPC::Run();
use Mojo::URL;
use Mojo::Util 'url_unescape';
use Regexp::Common 'URI';
use Try::Tiny;
use Mojo::File 'path';
use IO::Handle;
use IO::Socket::IP;
use Time::HiRes 'gettimeofday';
use POSIX 'strftime';
use Scalar::Util 'blessed';
use Mojo::Log;
use Scalar::Util qw(blessed reftype);
use Exporter 'import';

our $VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
our @EXPORT  = qw(
  $prj
  $basedir
  $prjdir
  $resultdir
  &data_name
  &needle_info
  &needledir
  &productdir
  &testcasedir
  &is_in_tests
  &log_debug
  &log_warning
  &log_info
  &log_error
  &log_fatal
  add_log_channel
  append_channel_to_defaults
  remove_log_channel
  remove_channel_from_defaults
  log_format_callback
  get_channel_handle
  &save_base64_png
  &run_cmd_with_log
  &run_cmd_with_log_return_error
  &parse_assets_from_settings
  &find_bugref
  &find_bugrefs
  bugref_regex
  &bugurl
  &bugref_to_href
  &href_to_bugref
  &url_to_href
  &find_bug_number
  &render_escaped_refs
  &asset_type_from_setting
  &check_download_url
  &check_download_whitelist
  &create_downloads_list
  &human_readable_size
  &locate_asset
  &job_groups_and_parents
  &detect_current_version
  wait_with_progress
  mark_job_linked
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
  &ensure_timestamp_appended
  set_listen_address
  service_port
);

our @EXPORT_OK = qw(base_host determine_web_ui_web_socket_url get_ws_status_only_url random_string random_hex);

if ($0 =~ /\.t$/) {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    $ENV{OPENQA_BASEDIR} ||= $tdirname . 'data';
}

#use lib "/usr/share/openqa/cgi-bin/modules";
use File::Basename;
use File::Spec;
use File::Spec::Functions qw(catfile catdir);
use Fcntl;
use Mojo::JSON qw(encode_json decode_json);
use Mojo::Util 'xml_escape';
our $basedir   = $ENV{OPENQA_BASEDIR} || "/var/lib";
our $prj       = "openqa";
our $prjdir    = "$basedir/$prj";
our $sharedir  = "$prjdir/share";
our $resultdir = "$prjdir/testresults";
our $assetdir  = "$sharedir/factory";
our $imagesdir = "$prjdir/images";
our $hostname  = $ENV{SERVER_NAME};
our $app;
my %channels     = ();
my %log_defaults = (LOG_TO_STANDARD_CHANNEL => 1, CHANNELS => []);

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
    return $dir . "/products/$distri" if -e "$dir/products/$distri";
    return $dir;
}

sub testcasedir {
    my ($distri, $version, $rootfortests) = @_;
    for my $dir (catdir($prjdir, 'share', 'tests'), catdir($prjdir, 'tests')) {
        $rootfortests ||= $dir if -d $dir;
    }
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
    my $abs_projdir = File::Spec->rel2abs($prjdir);
    return index($file, catdir($abs_projdir, 'share', 'tests')) == 0
      || index($file, catdir($abs_projdir, 'tests')) == 0;
}

# Call this when $prjdir is changed to re-evaluate all dependent directories
sub change_sharedir {
    $sharedir = shift;
    $assetdir = "$sharedir/factory";
}

sub needledir {
    my ($distri, $version) = @_;
    return productdir($distri, $version) . '/needles';
}

sub log_warning;

sub needle_info {
    my ($name, $distri, $version, $fn) = @_;
    local $/;

    my $needledir = needledir($distri, $version);

    if (!$fn) {
        $fn = "$needledir/$name.json";
    }
    elsif (!-f $fn) {
        $fn        = catfile($sharedir, $fn);
        $needledir = dirname($fn);
    }
    else {
        $needledir = dirname($fn);
    }

    my $JF;
    unless (open($JF, '<', $fn)) {
        log_warning("$fn: $!");
        return;
    }

    my $needle;
    try {
        $needle = decode_json(<$JF>);
    }
    catch {
        log_warning("failed to parse $fn: $_");
        # technically not required, $needle should remain undefined. Being superstitious human I add:
        undef $needle;
    }
    finally {
        close($JF);
    };
    return unless $needle;

    my $png_fname = basename($fn, '.json') . '.png';
    my $pngfile   = File::Spec->catpath('', $needledir, $png_fname);

    $needle->{needledir} = $needledir;
    $needle->{image}     = $pngfile;
    $needle->{json}      = $fn;
    $needle->{name}      = $name;
    $needle->{distri}    = $distri;
    $needle->{version}   = $version;

    # Skip code to support compatibility if HASH-workaround properties already present
    return $needle unless $needle->{properties};

    # Transform string-workaround-properties into HASH-workaround-properties
    $needle->{properties}
      = [map { ref($_) eq "HASH" ? $_ : {name => $_, value => find_bug_number($name)} } @{$needle->{properties}}];

    return $needle;
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

# logging helpers - _log_msg wrappers

# log_debug("message"[, param1=>val1, param2=>val2]);
# please check the _log_msg function for a brief description of the accepted params
# examples:
#  log_debug("message");
#  log_debug("message", channels=>'channel1')
#  log_debug("message", channels=>'channel1', standard=>0)
sub log_debug {
    _log_msg('debug', @_);
}

# log_info("message"[, param1=>val1, param2=>val2]);
sub log_info {

    _log_msg('info', @_);
}

# log_warning("message"[, param1=>val1, param2=>val2]);
sub log_warning {
    _log_msg('warn', @_);
}

# log_error("message"[, param1=>val1, param2=>val2]);
sub log_error {
    _log_msg('error', @_);
}

# log_fatal("message"[, param1=>val1, param2=>val2]);
sub log_fatal {
    _log_msg('fatal', @_);
    die $_[0];
}

sub _current_log_level {
    # FIXME: avoid use of $app here
    return defined $app && $app->can('log') && $app->log->can('level') && $app->log->level;
}

# The %options parameter is used to control which destinations the message should go.
# Accepted parameters: channels, standard.
#  - channels. Scalar or a arrayref containing the name of the channels to log to.
#  - standard. Boolean to indicate if it should use the *defaults* to log.
#
# If any of parameters above don't exist, this function will log to the defaults (by
# default it is $app). The standard option need to be set to true. Please check the function
# add_log_channel to learn on how to set a channel as default.
sub _log_msg {
    my ($level, $msg, %options) = @_;

    # use default options
    if (!%options) {
        return _log_msg(
            $level, $msg,
            channels => $log_defaults{CHANNELS},
            standard => $log_defaults{LOG_TO_STANDARD_CHANNEL});
    }

    # prepend process ID on debug level
    if (_current_log_level eq 'debug') {
        $msg = "[pid:$$] $msg";
    }

    # log to channels
    my $wrote_to_at_least_one_channel = 0;
    if (my $channels = $options{channels}) {
        for my $channel (ref($channels) eq 'ARRAY' ? @$channels : $channels) {
            $wrote_to_at_least_one_channel |= _log_to_channel_by_name($level, $msg, $channel);
        }
    }

    # log to standard (as fallback or when explicitely requested)
    if (!$wrote_to_at_least_one_channel || ($options{standard} // $log_defaults{LOG_TO_STANDARD_CHANNEL})) {
        # use Mojolicious app if available and otherwise just STDERR/STDOUT
        _log_via_mojo_app($level, $msg) or _log_to_stderr_or_stdout($level, $msg);
    }
}

sub _log_to_channel_by_name {
    my ($level, $msg, $channel_name) = @_;

    return 0 unless ($channel_name);
    my $channel = $channels{$channel_name} or return 0;
    return _try_logging_to_channel($level, $msg, $channel);
}

sub _log_via_mojo_app {
    my ($level, $msg) = @_;

    return 0 unless ($app && $app->log);
    return _try_logging_to_channel($level, $msg, $app->log);
}

sub _try_logging_to_channel {
    my ($level, $msg, $channel) = @_;

    eval { $channel->$level($msg); };
    return ($@ ? 0 : 1);
}

sub _log_to_stderr_or_stdout {
    my ($level, $msg) = @_;
    if ($level =~ /warn|error|fatal/) {
        STDERR->printflush("[@{[uc $level]}] $msg\n");
    }
    else {
        STDOUT->printflush("[@{[uc $level]}] $msg\n");
    }
}

# When a developer wants to log constantly to a channel he can either constantly pass the parameter
# 'channels' in the log_* functions, or when creating the channel, pass the parameter 'default'.
# This parameter can have two values:
# - "append". This value will append the channel to the defaults, so the simple call to the log_*
#   functions will try to log to the channels set as default.
# - "set". This value will replace all the defaults with the channel being created.
#
# All the parameters set in %options are passed to the Mojo::Log constructor.
sub add_log_channel {
    my ($channel, %options) = @_;
    if ($options{default}) {
        if ($options{default} eq 'append') {
            push @{$log_defaults{CHANNELS}}, $channel;
        }
        elsif ($options{default} eq 'set') {
            $log_defaults{CHANNELS}                = [$channel];
            $log_defaults{LOG_TO_STANDARD_CHANNEL} = 0;
        }
        delete $options{default};
    }
    $channels{$channel} = Mojo::Log->new(%options);

    $channels{$channel}->format(\&log_format_callback);
}

# The default format for logging
sub log_format_callback {
    my ($time, $level, @lines) = @_;
    # Unfortunately $time doesn't have the precision we want. So we need to use Time::HiRes
    $time = gettimeofday;
    return
      sprintf(strftime("[%FT%T.%%04d %Z] [$level] ", localtime($time)), 1000 * ($time - int($time)))
      . join("\n", @lines, '');
}

sub append_channel_to_defaults {
    my ($channel) = @_;
    push @{$log_defaults{CHANNELS}}, $channel if $channels{$channel};
}

# Removes a channel from defaults.
sub remove_channel_from_defaults {
    my ($channel) = @_;
    $log_defaults{CHANNELS}                = [grep { $_ ne $channel } @{$log_defaults{CHANNELS}}];
    $log_defaults{LOG_TO_STANDARD_CHANNEL} = 1 if !@{$log_defaults{CHANNELS}};
}

sub remove_log_channel {
    my ($channel) = @_;
    remove_channel_from_defaults($channel);
    delete $channels{$channel} if $channel;
}

sub get_channel_handle {
    my ($channel) = @_;
    if ($channel) {
        return $channels{$channel}->handle if $channels{$channel};
    }
    elsif ($app) {
        return $app->log->handle;
    }
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
        my $return_code       = $?;
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
            status      => $ipc_run_succeeded,
            return_code => $return_code,
            stderr      => $stdout_err,
        };
    }
    catch {
        return {
            status      => 0,
            return_code => undef,
            stderr      => "an internal error occured",
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
    return catfile($assetdir, $path);
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
    gh  => 'https://github.com/',
    kde => 'https://bugs.kde.org/show_bug.cgi?id=',
    fdo => 'https://bugs.freedesktop.org/show_bug.cgi?id=',
    jsc => 'https://jira.suse.de/browse/',
);
my %bugurls = (
    'https://bugzilla.novell.com/show_bug.cgi?id=' => 'bsc',
    $bugrefs{bsc}                                  => 'bsc',
    $bugrefs{boo}                                  => 'boo',
    $bugrefs{bgo}                                  => 'bgo',
    $bugrefs{brc}                                  => 'brc',
    $bugrefs{bko}                                  => 'bko',
    $bugrefs{poo}                                  => 'poo',
    $bugrefs{gh}                                   => 'gh',
    $bugrefs{kde}                                  => 'kde',
    $bugrefs{fdo}                                  => 'fdo',
    $bugrefs{jsc}                                  => 'jsc',
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
    $text =~ s(($RE{URI}))(<a href="$1">$1</a>)gx;
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
    # Passed a URL and the download_domains whitelist from openqa.ini.
    # Checks if the host of the URL is in the whitelist. Returns an
    # array: (1, host) if there is a whitelist and the host is not in
    # it, (2, host) if there is no whitelist, and () if we pass. This
    # is used by check_download_whitelist below (and so indirectly by
    # the Iso controller) and directly by the download_asset() Gru
    # task subroutine.
    my ($url, $whitelist) = @_;
    my @okdomains;
    if (defined $whitelist) {
        @okdomains = split(/ /, $whitelist);
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

sub check_download_whitelist {
    # Passed the params hash ref for a job and the download_domains
    # whitelist read from openqa.ini. Checks that all params ending
    # in _URL (i.e. requesting asset download) specify URLs that are
    # whitelisted. It's provided here so that we can run the check
    # twice, once to return immediately and conveniently from the Iso
    # controller, once again directly in the Gru asset download sub
    # just in case someone somehow manages to bypass the API and
    # create a gru task directly. On failure, returns an array of 4
    # items: the first is 1 if there was a whitelist at all or 2 if
    # there was not, the second is the name of the param for which the
    # check failed, the third is the URL, and the fourth is the host.
    # On success, returns an empty array.

    my ($params, $whitelist) = @_;
    my @okdomains;
    if (defined $whitelist) {
        @okdomains = split(/ /, $whitelist);
    }
    for my $param (keys %$params) {
        next unless ($param =~ /_URL$/);
        my $url   = $$params{$param};
        my @check = check_download_url($url, $whitelist);
        next unless (@check);
        # if we get here, we got a failure
        return ($check[0], $param, $url, $check[1]);
    }
    # empty list signals caller that check passed
    return ();
}

sub create_downloads_list {
    my ($args) = @_;
    my %downloads = ();
    for my $arg (keys %$args) {
        next unless ($arg =~ /_URL$/);
        # As this comes in from an API call, URL will be URI-encoded
        # This obviously creates a vuln if untrusted users can POST
        $args->{$arg} = url_unescape($args->{$arg});
        my $url        = $args->{$arg};
        my $do_extract = 0;
        my $short;
        my $filename;
        # if $args{FOO_URL} or $args{FOO_DECOMPRESS_URL} is set but $args{FOO}
        # is not, we will set $args{FOO} (the filename of the downloaded asset)
        # to the URL filename. This has to happen *before*
        # generate_jobs so the jobs have FOO set
        if ($arg =~ /_DECOMPRESS_URL$/) {
            $do_extract = 1;
            $short      = substr($arg, 0, -15);    # remove whole _DECOMPRESS_URL substring
        }
        else {
            $short = substr($arg, 0, -4);          # remove _URL substring
        }
        if (!$args->{$short}) {
            $filename = Mojo::URL->new($url)->path->parts->[-1];
            if ($do_extract) {
                # if user wants to extract downloaded file, final filename
                # will have last extension removed
                $filename = fileparse($filename, qr/\.[^.]*/);
            }
            $args->{$short} = $filename;
            if (!$args->{$short}) {
                OpenQA::Utils::log_warning("Unable to get filename from $url. Ignoring $arg");
                delete $args->{$short} unless $args->{$short};
                next;
            }
        }
        else {
            $filename = $args->{$short};
        }
        # We're only going to allow downloading of asset types. We also
        # need this to determine the download location later
        my $assettype = asset_type_from_setting($short, $args->{$short});
        unless ($assettype) {
            OpenQA::Utils::log_debug("_URL downloading only allowed for asset types! $short is not an asset type");
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
        return $p . _round_a_bit($size) . "KiB";
    }

    $size /= 1024.;
    if ($size < 1024) {
        return $p . _round_a_bit($size) . "MiB";
    }

    $size /= 1024.;
    return $p . _round_a_bit($size) . "GiB";
}

# query group parents and job groups and let the database sort it for us - and merge it afterwards
sub job_groups_and_parents {
    my $schema = $app->schema;
    my @parents
      = $schema->resultset('JobGroupParents')->search({}, {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]})
      ->all;
    my @groups_without_parent = $schema->resultset('JobGroups')
      ->search({parent_id => undef}, {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]})->all;
    my @res;
    my $first_parent = shift @parents;
    my $first_group  = shift @groups_without_parent;
    while ($first_parent || $first_group) {
        my $pick_parent
          = $first_parent && (!$first_group || ($first_group->sort_order // 0) > ($first_parent->sort_order // 0));
        if ($pick_parent) {
            push(@res, $first_parent);
            $first_parent = shift @parents;
        }
        else {
            push(@res, $first_group);
            $first_group = shift @groups_without_parent;
        }
    }
    return \@res;
}

# returns the search args for the job overview according to the parameter of the specified controller
sub compose_job_overview_search_args {
    my ($controller) = @_;
    my %search_args;

    # add simple query params to search args
    for my $arg (qw(distri version flavor build test)) {
        my $params      = $controller->every_param($arg) or next;
        my $param_count = scalar @$params;
        if ($param_count == 1) {
            $search_args{$arg} = $params->[0];
        }
        elsif ($param_count > 1) {
            $search_args{$arg} = {-in => $params};
        }
    }
    if (my $modules = param_hash($controller, 'modules')) {
        $search_args{modules} = [keys %$modules];
    }
    if ($controller->param('modules_result')) {
        $search_args{modules_result} = $controller->every_param('modules_result');
    }
    # add group query params to search args
    # (By 'every_param' we make sure to use multiple values for groupid and
    # group at the same time as a logical or, i.e. all specified groups are
    # returned.)
    my $schema = $controller->schema;
    my @groups;
    if ($controller->param('groupid') or $controller->param('group')) {
        my @group_id_search   = map { {id   => $_} } @{$controller->every_param('groupid')};
        my @group_name_search = map { {name => $_} } @{$controller->every_param('group')};
        my @search_terms = (@group_id_search, @group_name_search);
        @groups = $schema->resultset('JobGroups')->search(\@search_terms)->all;
    }

    # determine build number
    if (!$search_args{build}) {
        # yield the latest build of the first group if (multiple) groups but not build specified
        # note: the search arg 'groupid' is ignored by complex_query() because we later assign 'groupids'
        $search_args{groupid} = $groups[0]->id if (@groups);

        $search_args{build} = $schema->resultset('Jobs')->latest_build(%search_args);

        # print debug output
        if (@groups == 0) {
            $controller->app->log->debug(
                'No build and no group specified, will lookup build based on the other parameters');
        }
        elsif (@groups == 1) {
            $controller->app->log->debug('Only one group but no build specified, searching for build');
        }
        else {
            $controller->app->log->info('More than one group but no build specified, selecting build of first group');
        }
    }

    # exclude jobs which are already cloned by setting scope for OpenQA::Jobs::complex_query()
    $search_args{scope} = 'current';

    # allow filtering by job ID
    my $ids = $controller->every_param('id');
    $search_args{id} = $ids if ($ids && @$ids);
    # note: filter for results, states and failed modules are applied after the initial search
    #       so old jobs are not revealed by applying those filters

    # allow filtering by group ID or group name
    $search_args{groupids} = [map { $_->id } @groups] if (@groups);

    return (\%search_args, \@groups);
}

sub read_test_modules {
    my ($job) = @_;

    my $testresultdir = $job->result_dir();
    return unless $testresultdir;

    my $category;
    my $has_parser_text_results = 0;
    my @modlist;

    for my $module (OpenQA::Schema::Result::JobModules::job_modules($job)) {
        my $name = $module->name();
        # add link to $testresultdir/$name*.png via png CGI
        my @details;

        my $num                           = 1;
        my $has_module_parser_text_result = 0;

        for my $step (@{$module->details}) {
            my $text   = $step->{text};
            my $source = $step->{_source};

            $step->{num}           = $num++;
            $step->{display_title} = ($text ? $step->{title} : $step->{name}) // '';
            if ($text) {
                my $file = path($job->result_dir(), $text);
                if (-e $file) {
                    log_debug("Reading information from " . encode_json($step));
                    $step->{text_data} = $file->slurp;
                }
                else {
                    log_debug("Cannot read file: $file");
                }
            }

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
                name                   => $module->name,
                result                 => $module->result,
                details                => \@details,
                milestone              => $module->milestone,
                important              => $module->important,
                fatal                  => $module->fatal,
                always_rollback        => $module->always_rollback,
                has_parser_text_result => $has_module_parser_text_result,
            });

        if (!$category || $category ne $module->category) {
            $category = $module->category;
            $modlist[-1]->{category} = $category;
        }

    }

    return {
        modules                 => \@modlist,
        has_parser_text_results => $has_parser_text_results,
    };
}

sub wait_with_progress {
    my ($interval) = @_;
    my $tics;
    local $| = 1;

    do {
        $tics++;
        sleep(1);
        print ".";
    } while ($interval > $tics);

    print "\n";
}

sub mark_job_linked {
    my ($jobid, $referer_url) = @_;

    my $referer = Mojo::URL->new($referer_url)->host;
    my $schema  = $app->schema;
    if ($referer && grep { $referer eq $_ } @{$app->config->{global}->{recognized_referers}}) {
        my $job = $schema->resultset('Jobs')->find({id => $jobid});
        return unless $job;
        my $found    = 0;
        my $comments = $job->comments;
        while (my $comment = $comments->next) {
            if (($comment->label // '') eq 'linked') {
                $found = 1;
                last;
            }
        }
        unless ($found) {
            my $user = $schema->resultset('Users')->search({username => 'system'})->first;
            $comments->create(
                {
                    text    => "label:linked Job mentioned in $referer_url",
                    user_id => $user->id
                });
        }
    }
    elsif ($referer) {
        log_debug("Unrecognized referer '$referer'");
    }
}

# parse comments of the specified (parent) group and store all mentioned builds in $res (hashref)
sub parse_tags_from_comments {
    my ($group, $res) = @_;

    my $comments = $group->comments;
    return unless ($comments);

    while (my $comment = $comments->next) {
        my @tag   = $comment->tag;
        my $build = $tag[0];
        next unless $build;

        my $version = $tag[3];
        my $tag_id  = $version ? "$version-$build" : $build;

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
    my $changelog_file  = path($path, 'public', 'Changelog');
    my $head_file       = path($path, '.git', 'refs', 'heads', 'master');
    my $refs_file       = path($path, '.git', 'packed-refs');

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
            my $latest_ref   = (grep(/tags/, split(/\s/, $packed_refs)))[-1];
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
    while (my ($key, $value) = each %$hash) {
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
        webui       => 0,
        websocket   => 1,
        livehandler => 2,
        scheduler   => 3
    };
    croak "Unknown service: $service" unless exists $offsets->{$service};
    return $base + $offsets->{$service};
}

sub random_string {
    my ($length, $chars) = @_;
    $length //= 16;
    $chars  //= ['a' .. 'z', 'A' .. 'Z', '0' .. '9', '_'];
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

sub param_hash {
    my ($controller, $param_name) = @_;

    my $params = $controller->every_param($param_name) or return;
    my %hash;
    for my $param (@$params) {
        # ignore empty params
        next unless $param;
        # allow passing multiple values by separating them with comma
        $hash{$_} = 1 for split(',', $param);
    }
    return unless (%hash);
    return \%hash;
}

sub any_array_item_contained_by_hash {
    my ($array, $hash) = @_;

    for my $array_item (@$array) {
        return 1 if ($hash->{$array_item});
    }
    return 0;
}

sub base_host { Mojo::URL->new($_[0])->host || $_[0] }

1;
