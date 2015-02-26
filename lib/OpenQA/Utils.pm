package OpenQA::Utils;
use strict;
require 5.002;

use Carp;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = qw(
  $prj
  $basedir
  $resultdir
  $app_title
  $app_subtitle
  &running_log
  &data_name
  &needle_info
  &needledir
  &testcasedir
  &test_resultfile_list
  &testresultdir
  &test_uploadlog_list
  $localstatedir
  &get_failed_needles
  &file_content
  &log_debug
);


if ($0 =~ /\.t$/) {
    # This should result in the 't' directory, even if $0 is in a subdirectory
    my ($tdirname) = $0 =~ qr/((.*\/t\/|^t\/)).+$/;
    $ENV{OPENQA_BASEDIR} ||= $tdirname.'data';
}

#use lib "/usr/share/openqa/cgi-bin/modules";
use File::Basename;
use Fcntl;
use JSON "decode_json";
our $basedir=$ENV{'OPENQA_BASEDIR'}||"/var/lib";
our $prj="openqa";
our $resultdir="$basedir/$prj/testresults";
our $assetdir="$basedir/$prj/factory";
our $isodir="$assetdir/iso";
our $cachedir="$basedir/$prj/cache";
our $hostname=$ENV{'SERVER_NAME'};
our $app_title = 'openQA test instance';
our $app_subtitle = 'openSUSE automated testing';
our $testcasedir = "$basedir/openqa/share/tests";
our $applog;

sub running_log($) {
    my ($name) = @_;
    return join('/', $basedir, $prj, 'testresults', $name, '/');
}

sub testcasedir($$) {
    my $distri = shift;
    my $version = shift;

    my $dir = "$testcasedir/$distri";
    $dir .= "-$version" if $version && -e "$dir-$version";

    return $dir;
}

sub testresultdir($) {
    my $fn=shift;
    "$basedir/$prj/testresults/$fn";
}

sub test_resultfile_list($) {
    # get a list of existing resultfiles
    my $testname = shift;
    my $testresdir = testresultdir($testname);
    my @filelist = qw(video.ogv results.json vars.json backend.json serial0.txt autoinst-log.txt);
    my @filelist_existing;
    for my $f (@filelist) {
        if(-e "$testresdir/$f") {
            push(@filelist_existing, $f);
        }
    }
    return @filelist_existing;
}

sub test_uploadlog_list($) {
    # get a list of uploaded logs
    my $testname = shift;
    my $testresdir = testresultdir($testname);
    my @filelist;
    for my $f (<$testresdir/ulogs/*>) {
        $f=~s#.*/##;
        push(@filelist, $f);
    }
    return @filelist;
}

sub data_name($) {
    $_[0]=~m/^.*\/(.*)\.\w\w\w(?:\.gz)?$/;
    return $1;
}

sub needledir($$) {
    return testcasedir($_[0], $_[1]).'/needles';
}

sub needle_info($$$) {
    my $name = shift;
    my $distri = shift;
    my $version = shift;
    local $/;

    my $needledir = needledir($distri, $version);

    my $fn = "$needledir/$name.json";
    unless (open(JF, '<', $fn )) {
        warn "$fn: $!";
        return undef;
    }

    my $needle;
    eval {$needle = decode_json(<JF>);};
    close(JF);

    if($@) {
        warn "failed to parse $needledir/$name.json: $@";
        return undef;
    }

    $needle->{'needledir'} = $needledir;
    $needle->{'image'} = "$needledir/$name.png";
    $needle->{'json'} = "$needledir/$name.json";
    $needle->{'name'} = $name;
    $needle->{'distri'} = $distri;
    $needle->{'version'} = $version;
    return $needle;
}

# actually it's also return failed modules
sub get_failed_needles($){
    my $testname = shift;
    return undef if !defined($testname);

    my $testresdir = testresultdir($testname);
    my $glob = "$testresdir/results.json";
    my $failures = {};
    my @failedneedles = ();
    my @failedmodules = ();
    for my $fn (glob $glob) {
        local $/; # enable localized slurp mode
        next unless -e $fn;
        open(my $fd, '<', $fn);
        next unless $fd;
        my $results = decode_json(<$fd>);
        close $fn;
        for my $module (@{$results->{testmodules}}) {
            next unless $module->{result} eq 'fail';
            push( @failedmodules, $module->{name} );
            for my $detail (@{$module->{details}}) {
                next unless $detail->{result} eq 'fail';
                next unless $detail->{needles};
                for my $needle (@{$detail->{needles}}) {
                    push( @failedneedles, $needle->{name} );
                }
                $failures->{$testname}->{failedneedles} = \@failedneedles;
            }
            $failures->{$testname}->{failedmodules} = \@failedmodules;
        }
    }
    return $failures;
}

sub file_content($){
    my($fn)=@_;
    open(FCONTENT, "<", $fn) or return undef;
    local $/;
    my $result=<FCONTENT>;
    close(FCONTENT);
    return $result;
}

sub log_debug {
    # useful for models, but doesn't work in tests
    $applog->debug(shift) if $applog;
}

1;
# vim: set sw=4 et:
