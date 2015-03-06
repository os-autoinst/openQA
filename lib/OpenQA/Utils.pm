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
  &data_name
  &needle_info
  &needledir
  &testcasedir
  &testresultdir
  &file_content
  &log_debug
  &save_base64_png
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

sub testcasedir($$) {
    my $distri = shift;
    my $version = shift;

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
    my $default_margin = 50; # define in os-autoinst
    my $default_match = 96; # define in os-autoinst

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

    # set the value if the needle doesn't have that value
    @{$needle->{'area'}}[0]->{'margin'} = $default_margin if !defined @{$needle->{'area'}}[0]->{'margin'};
    @{$needle->{'area'}}[0]->{'match'} = $default_match if !defined @{$needle->{'area'}}[0]->{'match'};

    $needle->{'needledir'} = $needledir;
    $needle->{'image'} = "$needledir/$name.png";
    $needle->{'json'} = "$needledir/$name.json";
    $needle->{'name'} = $name;
    $needle->{'distri'} = $distri;
    $needle->{'version'} = $version;
    return $needle;
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

1;
# vim: set sw=4 et:
