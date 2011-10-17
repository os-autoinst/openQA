#!/usr/bin/perl -w
# usage: find -name \*.rpm | recentchanges.pl
use strict;
use Time::Local;
use Getopt::Long;
use changedb;
$ENV{LANG}="C";
#my @pkgs=("terminfo-5.6-90.55","yast2-schema-2.17.4-1.52");
#my @weekday=qw(Sun Mon Tue Wed Thu Fri Sat);
my %month=qw(Jan 1 Feb 2 Mar 3 Apr 4 May 5 Jun 6 Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12);
my @options=(qw"since=i for=s help|h|?");
my %options=(
	"for"=>"10d" # last 10 days
);
if(!GetOptions(\%options, @options) || (@ARGV && $ARGV[0] ne "")) {die "invalid option @ARGV\n"}


sub parsedate($)
{ my $entry=shift;
	my ($year,$month,$day);
	return 0 if($entry!~m/\S/ || $entry eq "(none)");
	if($entry=~m/^(\w{3}) (\d{2}) (\d{4})/) {
		($year,$month,$day)=($3,$month{$1},$2);

	} else {return 0} #else {die "could not parse date in $entry"}
	return timegm(0,0,0, $day, $month-1, $year);
#	return $day+31*$month+366*$year;
}

my $freshtime=$options{since} || rel_time($options{for});
my $archre=qr((?:i[3456]86)|(?:x86_64)|noarch);
my $build=`cat /opensuse/factory/repo/oss/media.1/build`; chomp($build); $build=~s/.*(\d{4})$/$1/;
my $buildid=time." $build";

my %fileseen;
{
	open(my $f, "fileseen");
	while(<$f>) {
		chomp;
		$fileseen{$_}=1;
	}
}
open(my $fileseen, ">>", "fileseen") or die $!;

while(my $p=<>) {
	my $fullname=$p;
	chomp($p);
	$p=~s{^.*/}{}; # drop path
	my $filename=$p;
	next if $fileseen{$p};
	my $changes=`rpm -qp --changelog $fullname`;
	$changes=~s/\@/ /g;
	$p=~s/\.rpm$//;
	$p=~s/-([^-]+-\d+\.\d+)\.$archre$//;
	my $ver=$1;
	foreach my $entry (split(/^\* (?:Mon|Tue|Wed|Thu|Fri|Sat|Sun) /m, $changes)) {
		my $time=parsedate($entry);
		next unless $time>$freshtime;
		$entry=~s/\s+$//s;
		#print "time=$time entry=$entry";
		my $sig="$p: $time $entry";
		last unless add_change($sig, $buildid);
		print "* $p ver=$ver: $time $entry\n";
	}
	print $fileseen "$filename\n";
}
