#!/usr/bin/perl -w
use strict;
# test for https://bugzilla.novell.com/show_bug.cgi?id=657626

sub settime($)
{ my $time=shift;
	my ($sec,$min,$hour,$mday,$mon,$year)=localtime($time);
	$year+=1900; $mon++;
	system(qw"date --set", sprintf("%04i-%02i-%02i %02i:%02i:%02i", $year, $mon, $mday, $hour, $min, $sec));
}

my $now=time;
my $timediff=600;
my $badtime=$now+$timediff;
settime($badtime);
my $t1=time;
# sntp is expected to fetch the right (older) time
#system(qw"sntp -d -s pool.ntp.org");
system(qw"sntp -d -s ntp.zq1.de");
if(($?>>8)!=0) {die "sntp failed: $? $!"}
my $t2=time;

print "$now $badtime $t1 $t2\n";

if($t2>=$t1) {
	settime($now); # cleanup
	print "sntp failed!\n";
	exit 2 if($t2<$t1+$timediff/2); # known bug
	exit 1;
}
exit 0;
