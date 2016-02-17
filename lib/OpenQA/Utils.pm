package OpenQA::Utils;
use strict;
require 5.002;

use Carp;
use IPC::Run();
use Mojo::URL;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA     = qw(Exporter);
@EXPORT  = qw(
  $prj
  $basedir
  $resultdir
  &data_name
  &needle_info
  &needledir
  &productdir
  &testcasedir
  &testresultdir
  &file_content
  &log_debug
  &save_base64_png
  &run_cmd_with_log
  &commit_git
  &parse_assets_from_settings
  &bugurl
  &bugref_to_href
  &asset_type_from_setting
  &check_download_url
  &check_download_whitelist
);


if ($0 =~ /\.t$/) {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    $ENV{OPENQA_BASEDIR} ||= $tdirname . 'data';
}

#use lib "/usr/share/openqa/cgi-bin/modules";
use File::Basename;
use Fcntl;
use JSON "decode_json";
our $basedir     = $ENV{OPENQA_BASEDIR} || "/var/lib";
our $prj         = "openqa";
our $resultdir   = "$basedir/$prj/testresults";
our $assetdir    = "$basedir/$prj/factory";
our $isodir      = "$assetdir/iso";
our $imagesdir   = "$basedir/$prj/images";
our $hostname    = $ENV{SERVER_NAME};
our $testcasedir = "$basedir/openqa/share/tests";
our $app;

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
    my ($distri, $version) = @_;

    my $dir = testcasedir($distri, $version);
    return $dir . "/products/$distri" if -e "$dir/products/$distri";
    return $dir;
}

sub testcasedir($$) {
    my $distri  = shift;
    my $version = shift;
    # TODO actually "distri" is misused here. It should rather be something
    # like the name of the repository with all tests
    my $dir = "$testcasedir/$distri";
    $dir .= "-$version" if $version && -e "$dir-$version";

    return $dir;
}

sub testresultdir($) {
    my ($fn) = @_;
    confess "FN" unless ($fn);
    "$basedir/$prj/testresults/$fn";
}

sub data_name($) {
    $_[0] =~ m/^.*\/(.*)\.\w\w\w(?:\.gz)?$/;
    return $1;
}

sub needledir {
    my ($distri, $version) = @_;
    return productdir($distri, $version) . '/needles';
}

sub needle_info($$$) {
    my $name    = shift;
    my $distri  = shift;
    my $version = shift;
    local $/;

    my $needledir = needledir($distri, $version);

    my $fn = "$needledir/$name.json";
    my $JF;
    unless (open($JF, '<', $fn)) {
        warn "$fn: $!";
        return;
    }

    my $needle;
    eval { $needle = decode_json(<$JF>); };
    close($JF);

    if ($@) {
        warn "failed to parse $needledir/$name.json: $@";
        return;
    }

    $needle->{needledir} = $needledir;
    $needle->{image}     = "$needledir/$name.png";
    $needle->{json}      = "$needledir/$name.json";
    $needle->{name}      = $name;
    $needle->{distri}    = $distri;
    $needle->{version}   = $version;
    return $needle;
}

sub file_content($) {
    my ($fn) = @_;
    open(my $FCONTENT, "<", $fn) or return;
    local $/;
    my $result = <$FCONTENT>;
    close($FCONTENT);
    return $result;
}

sub log_debug {
    # useful for models, but doesn't work in tests
    $app->log->debug(shift) if $app && $app->log;
}

sub log_info {
    # useful for models, but doesn't work in tests
    $app->log->info(shift) if $app && $app->log;
}

sub log_warning {
    # useful for models, but doesn't work in tests
    $app->log->warn(shift) if $app && $app->log;
}

sub log_error {
    # useful for models, but doesn't work in tests
    $app->log->error(shift) if $app && $app->log;
}

sub save_base64_png($$$) {
    my ($dir, $newfile, $png) = @_;
    return unless $newfile;
    # sanitize
    $newfile =~ s,\.png,,;
    $newfile =~ tr/a-zA-Z0-9-/_/cs;
    open(my $fh, ">", $dir . "/$newfile.png") || die "can't open $dir/$newfile.png: $!";
    use MIME::Base64 qw/decode_base64/;
    $fh->print(decode_base64($png));
    close($fh);
    return $newfile;
}

sub image_md5_filename($) {
    my ($md5) = @_;

    my $prefix = substr($md5, 0, 2);
    $md5 = substr($md5, 2);
    return ($imagesdir . "/$prefix/$md5.png", $imagesdir . "/$prefix/.thumbs/$md5.png");
}

sub run_cmd_with_log($) {
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
    return $ret;
}

sub commit_git {
    my ($args) = @_;

    my $dir = $args->{dir};
    if ($dir !~ /^\//) {
        use Cwd qw/abs_path/;
        $dir = abs_path($dir);
    }
    my @git = ('git', '--git-dir', "$dir/.git", '--work-tree', $dir);
    my @files;

    for my $cmd (qw(add rm)) {
        next unless $args->{$cmd};
        push(@files, @{$args->{$cmd}});
        unless (run_cmd_with_log([@git, $cmd, @{$args->{$cmd}}])) {
            return;
        }
    }

    my $message = $args->{message};
    my $user    = $args->{user};
    my $author  = sprintf('--author=%s <%s>', $user->fullname, $user->email);
    unless (run_cmd_with_log([@git, 'commit', '-q', '-m', $message, $author, @files])) {
        return;
    }

    if (($app->config->{'scm git'}->{do_push} || '') eq 'yes') {
        unless (run_cmd_with_log([@git, 'push'])) {
            return;
        }
    }
    return 1;
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

sub bugurl {
    my ($bugref) = @_;
    my %bugrefs = (
        bnc => 'https://bugzilla.novell.com/show_bug.cgi?id=',
        bsc => 'https://bugzilla.suse.com/show_bug.cgi?id=',
        boo => 'https://bugzilla.opensuse.org/show_bug.cgi?id=',
        poo => 'https://progress.opensuse.org/issues/',
    );
    return $bugrefs{$bugref};
}

sub bugref_to_href {
    my ($text) = @_;

    $text =~ s{((bnc|bsc|boo|poo)#(\d+))}{<a href="@{[bugurl($2)]}$3">$1</a>}gi;

    return $text;
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

1;
# vim: set sw=4 et:
