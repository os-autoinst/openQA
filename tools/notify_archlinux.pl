#!/usr/bin/perl -w
use strict;
use lib "/srv/www/cgi-bin/modules";
use awstandard;
use openqa;

use URI::Escape;

my $COOKIEFILE="/tmp/archsubmitcookie";
my $FORMURL="http://www.archlinux.org/releng/feedback/submit/";

my $testname = shift;
my ($distribution,$instsource,$architekture,$build) = split('-', $testname);
my $filesystem = ($testname=~m/btrfs/)?'btrfs':'ext4';

die('no archlinux test') unless($distribution eq 'archlinux');

my @lines = parse_log(resultname_to_log($testname));
die "no log" if not @lines;
my $result = parse_log_to_hash(\@lines);
my $testresult = lc($result->{overall});

`rm -f $COOKIEFILE`;

my $formhtml=`curl -c $COOKIEFILE -s $FORMURL`;

my %iso_val;
while($formhtml=~m/option value="(\d+)">(\d{4}.\d{2}.\d{2})_/g) {
	$iso_val{$2} = $1; 
}

die("build is too old") unless($iso_val{$build});

my %architekture_val = ('i686' => '3', 'x86_64' => 4); 
my %iso_type_val = ('core' => '1', 'netinst', '2');
my %source_val = ('core' => '3', 'netinst', '2');
my %modules_val = ('ext4' => '8', 'btrfs' => '5');

my %form;
if($formhtml=~m/name='csrfmiddlewaretoken' value='(\w+)'/) {
	$form{csrfmiddlewaretoken} = $1; 
}
$form{boot_type} = '1'; # optical medium
$form{hardware_type} = '2'; # qemu
$form{install_type} = '1'; # interactive install
$form{clock_choice} = '6'; # update region/timezone, keep clock
$form{filesystem} = '1'; # autoprepare
$form{bootloader} = '1'; # grub
$form{rollback_filesystem} = ''; 
$form{user_name} = 'openQA';
$form{user_email} = 'dheidler@suse.de';
$form{website} = ''; # no value (looks like a honeypot)

$form{architekture} = $architekture_val{$architekture};
$form{iso_type} = $iso_type_val{$instsource};
$form{source} = $source_val{$instsource};
$form{modules} = $modules_val{$filesystem};
$form{iso} = $iso_val{$build};

$form{comments} = "openQA Autoinst\nMore details: http://openqa.opensuse.org/results/$testname";
if($testresult eq 'ok') {
	$form{success} = 'checked';
}

my @form_data = map { "$_=".uri_escape($form{$_}) } keys %form;
my $form_data_string = join('&', @form_data);

if($testresult eq 'fail') {
	# as we do not test everything, we can only report fails
	print "curl -b $COOKIEFILE -d \"$form_data_string\" -s $FORMURL\n";
}

`rm -f $COOKIEFILE`
