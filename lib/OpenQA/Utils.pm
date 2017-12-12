# Copyright (C) 2012-2017 SUSE LLC
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
require 5.002;

use Carp;
use IPC::Run();
use Mojo::URL;
use Regexp::Common 'URI';
use Try::Tiny;
use Mojo::File 'path';
use IO::Handle;
use Time::HiRes 'gettimeofday';
use POSIX 'strftime';
use Scalar::Util 'blessed';
use Data::Dump 'pp';
use Mojo::Log;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA     = qw(Exporter);
@EXPORT  = qw(
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
  &commit_git
  &commit_git_return_error
  &parse_assets_from_settings
  &find_bugref
  &find_bugrefs
  &bugurl
  &bugref_to_href
  &href_to_bugref
  &url_to_href
  &render_escaped_refs
  &asset_type_from_setting
  &check_download_url
  &check_download_whitelist
  &human_readable_size
  &locate_asset
  &job_groups_and_parents
  &find_job
  &detect_current_version
  wait_with_progress
  mark_job_linked
  path_to_class
  loaded_modules
  loaded_plugins
  hashwalker
  send_job_to_worker
  wakeup_scheduler
  read_test_modules
  exists_worker
  safe_call
  feature_scaling
  logistic_map_steps
  logistic_map
  rand_range
  in_range
);

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
use Cpanel::JSON::XS "decode_json";
use Mojo::Util 'xml_escape';
our $basedir   = $ENV{OPENQA_BASEDIR} || "/var/lib";
our $prj       = "openqa";
our $prjdir    = "$basedir/$prj";
our $sharedir  = "$prjdir/share";
our $resultdir = "$prjdir/testresults";
our $assetdir  = "$sharedir/factory";
our $isodir    = "$assetdir/iso";
our $hdddir    = "$assetdir/hdd";
our $otherdir  = "$assetdir/other";
our $imagesdir = "$prjdir/images";
our $hostname  = $ENV{SERVER_NAME};
our $app;
my %channels = ();
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
    $isodir   = "$assetdir/iso";
    $hdddir   = "$assetdir/hdd";
    $otherdir = "$assetdir/other";
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
        $fn = catfile($sharedir, $fn);
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
    my $pngfile = File::Spec->catpath('', $needledir, $png_fname);

    $needle->{needledir} = $needledir;
    $needle->{image}     = $pngfile;
    $needle->{json}      = $fn;
    $needle->{name}      = $name;
    $needle->{distri}    = $distri;
    $needle->{version}   = $version;
    return $needle;
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

# The %options parameter is used to control which destinations the message should go.
# Accepted parameters: channels, standard.
#  - channels. Scalar or a arrayref containing the name of the channels to log to.
#  - standard. Boolean to indicate if it should use the *defaults*  to log.
#
#  This function is used together with _log, and if any of parameters above don't exist,
#  then it will log to the defaults (by default is $app) - the standard option need to be
#  set to true. Please check the function add_log_channel to learn on how to set a
#  channel as default
sub _log_msg {
    my ($level, $msg, %options) = @_;
    my $log_to_standard = 0;

    if (!%options) {
        # set defaults
        _log_msg($level, $msg, channels => $log_defaults{CHANNELS}, standard => $log_defaults{LOG_TO_STANDARD_CHANNEL});
        $log_to_standard = 0;
    }
    else {

        if ($options{channels}) {
            if (ref($options{channels}) eq 'ARRAY') {
                for my $channel (@{$options{channels}}) {
                    _log($level, $msg, $channel);
                }
            }
            else {

                _log($level, $msg, $options{channels});
            }
        }
        $log_to_standard = $options{standard} // $log_defaults{LOG_TO_STANDARD_CHANNEL};
    }

    _log($level, $msg) if $log_to_standard;
}

# There are three possibilities for logging:
# 1- Logging to a channel
# 2- Logging to the default destination
# 3- Logging to the STDERR/STDOUT as a fallback in case of none of the above are set
sub _log {
    my ($level, $msg, $channel) = @_;

    if ($channel && $channels{$channel}) {
        $channels{$channel}->$level($msg);
    }
    elsif ($app && $app->log) {
        $app->log->$level($msg);
    }
    else {
        if ($level =~ /warn|error|fatal/) {
            STDERR->printflush("[@{[uc $level]}] $msg\n");
        }
        else {
            STDOUT->printflush("[@{[uc $level]}] $msg\n");
        }
    }
}

# When a developer wants to log constantly to a channel he can either constantly pass the parameter
# 'channels' in the log_* functions, or when creating the channel, pass the parameter 'default'.
# This parameter can have two values:
# - "append". This value will append the channel to the defaults, so the simple call to the log_*
#   functions will try to log to the channels set as default.

# - "set". This value will replace all the defaults with the channel being created.

# All the parameters set in %options are passed to the Mojo::Log constructor
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
    $log_defaults{CHANNELS} = [grep { $_ ne $channel } @{$log_defaults{CHANNELS}}];
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

sub save_base64_png($$$) {
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

sub run_cmd_with_log($) {
    my ($cmd) = @_;
    return run_cmd_with_log_return_error($cmd)->{status};
}

sub run_cmd_with_log_return_error($) {
    my ($cmd) = @_;
    my ($stdin, $stdout_err, $ret);
    log_info('Running cmd: ' . join(' ', @$cmd));
    $ret = IPC::Run::run($cmd, \$stdin, '>&', \$stdout_err);
    chomp $stdout_err;
    if ($ret) {
        log_debug($stdout_err);
        log_info('cmd returned 0');
    }
    else {
        log_warning($stdout_err);
        log_error('cmd returned non-zero value');
    }
    return {
        status => $ret,
        stderr => $stdout_err
    };
}

sub commit_git {
    my ($args) = @_;
    return commit_git_return_error($args) ? undef : 1;
}

sub commit_git_return_error {
    my ($args) = @_;

    my $dir = $args->{dir};
    if ($dir !~ /^\//) {
        use Cwd 'abs_path';
        $dir = abs_path($dir);
    }
    my @git = ('git', '--git-dir', "$dir/.git", '--work-tree', $dir);
    my @files;

    for my $cmd (qw(add rm)) {
        next unless $args->{$cmd};
        push(@files, @{$args->{$cmd}});
        my $res = run_cmd_with_log_return_error([@git, $cmd, @{$args->{$cmd}}]);
        if (!$res->{status}) {
            my $error = 'Unable to add/rm via Git';
            $error .= ': ' . $res->{stderr} if $res->{stderr};
            return $error;
        }
    }

    my $message = $args->{message};
    my $user    = $args->{user};
    my $author  = sprintf('--author=%s <%s>', $user->fullname, $user->email);
    my $res     = run_cmd_with_log_return_error([@git, 'commit', '-q', '-m', $message, $author, @files]);
    if (!$res->{status}) {
        my $error = 'Unable to commit via Git';
        $error .= ': ' . $res->{stderr} if $res->{stderr};
        return $error;
    }

    if (($app->config->{'scm git'}->{do_push} || '') eq 'yes') {
        $res = run_cmd_with_log_return_error([@git, 'push']);
        if (!$res->{status}) {
            my $error = 'Unable to push Git commit';
            $error .= ': ' . $res->{stderr} if $res->{stderr};
            return $error;
        }
    }
    return 0;
}

sub asset_type_from_setting {
    my ($setting) = @_;
    if ($setting eq 'ISO' || $setting =~ /^ISO_\d$/) {
        return 'iso';
    }
    if ($setting =~ /^HDD_\d$/) {
        return 'hdd';
    }
    if ($setting =~ /^REPO_\d$/) {
        return 'repo';
    }
    if ($setting =~ /^ASSET_\d$/ || $setting eq 'KERNEL' || $setting eq 'INITRD') {
        return 'other';
    }
    # empty string if this doesn't look like an asset type
    return '';
}

sub parse_assets_from_settings {
    my ($settings) = (@_);
    my $assets = {};

    for my $k (keys %$settings) {
        my $type = asset_type_from_setting($k);
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
);

sub bugref_regex {
    my $marker = join('|', keys %bugrefs);
    my $repo_re = qr{[a-zA-Z/-]+};
    # <marker>[#<project/repo>]#<id>
    return qr{(?<![\(\[\"\>])(?<match>(?<marker>$marker)\#?(?<repo>$repo_re)?\#(?<id>\d+))(?![\w\"])};
}

sub find_bugref {
    my ($text) = @_;
    $text =~ bugref_regex;
    return $+{match};
}

sub find_bugrefs {
    my ($text) = @_;
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
    my $regex = join('|', keys %bugurls) =~ s/\?/\\\?/gr;
    # <repo> is optional, e.g. for github. For github issues and pull are
    # interchangeable, see comment in 'bugurl', too
    $regex = qr{(?<!["\(\[])(?<url_root>$regex)((?<repo>.*)/(issues|pull)/)?(?<id>\d+)(?![\w])};
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
        my $url = $$params{$param};
        my @check = check_download_url($url, $whitelist);
        next unless (@check);
        # if we get here, we got a failure
        return ($check[0], $param, $url, $check[1]);
    }
    # empty list signals caller that check passed
    return ();
}

sub send_job_to_worker {
    my $ipc = OpenQA::IPC->ipc;
    my $job = shift;
    my $res;
    # ugly work around for Net::DBus::Test not being able to handle us using low level API
    return if ref($ipc->{bus}->get_connection) eq 'Net::DBus::Test::MockConnection';
    return $ipc->websockets('ws_send_job', $job);
}

sub wakeup_scheduler {
    my $ipc = OpenQA::IPC->ipc;

    my $con = $ipc->{bus}->get_connection;

    # ugly work around for Net::DBus::Test not being able to handle us using low level API
    return if ref($con) eq 'Net::DBus::Test::MockConnection';

    my $msg = $con->make_method_call_message(
        "org.opensuse.openqa.Scheduler",
        "/Scheduler", "org.opensuse.openqa.Scheduler",
        "wakeup_scheduler"
    );
    # do not wait for a reply - avoid deadlocks. this way we can even call it
    # from within the scheduler without having to worry about reentering
    $con->send($msg);
}

sub exists_worker($$) {
    my $schema   = shift;
    my $workerid = shift;
    die "invalid worker id\n" unless $workerid;
    my $rs = $schema->resultset("Workers")->find($workerid);
    die "invalid worker id $workerid\n" unless $rs;
    return $rs;
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
    $size = abs($size) / 1024.;
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
    my @parents
      = $app->db->resultset('JobGroupParents')->search({}, {order_by => [{-asc => 'sort_order'}, {-asc => 'name'}]})
      ->all;
    my @groups_without_parent = $app->db->resultset('JobGroups')
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

sub find_job {
    my ($controller, $job_id) = @_;

    my $job = $controller->app->schema->resultset('Jobs')->find(int($job_id));
    if (!$job) {
        $controller->render(json => {error => 'Job does not exist'}, status => 404);
        return;
    }

    return $job;
}

sub read_test_modules {
    my ($job) = @_;

    my $testresultdir = $job->result_dir();
    return [] unless $testresultdir;

    my $category;
    my @modlist;

    for my $module (OpenQA::Schema::Result::JobModules::job_modules($job)) {
        my $name = $module->name();
        # add link to $testresultdir/$name*.png via png CGI
        my @details;

        my $num = 1;

        for my $step (@{$module->details}) {
            $step->{num} = $num++;
            push(@details, $step);
        }

        push(
            @modlist,
            {
                name      => $module->name,
                result    => $module->result,
                details   => \@details,
                milestone => $module->milestone,
                important => $module->important,
                fatal     => $module->fatal
            });

        if (!$category || $category ne $module->category) {
            $category = $module->category;
            $modlist[-1]->{category} = $category;
        }

    }

    return \@modlist;
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
    if ($referer && grep { $referer eq $_ } @{$app->config->{global}->{recognized_referers}}) {
        my $job = $app->db->resultset('Jobs')->find({id => $jobid});
        return unless $job;
        my $found    = 0;
        my $comments = $job->comments;
        while (my $comment = $comments->next) {
            if ($comment->label eq 'linked') {
                $found = 1;
                last;
            }
        }
        unless ($found) {
            my $user = $app->db->resultset('Users')->search({username => 'system'})->first;
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

sub safe_call {
    # no critic is for symbol de/reference
    no strict 'refs';    ## no critic
    my $ret;
    log_debug("Safe call: " . pp(@_));
    eval {
        $ret
          = blessed $_[0] ? [+shift->${\+shift()}(splice @_, 1)]
          : *{"$_[0]::$_[1]"}{CODE} ? [*{"$_[0]::$_[1]"}{CODE}(splice @_, 2)]
          :                           die(qq|Can't locate object method "$_[1]" via package "$_[0]"|);
    };
    if ($@) {
        log_error("Safe call error: $@");
        return [];
    }
    return $ret;
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


1;
# vim: set sw=4 et:
