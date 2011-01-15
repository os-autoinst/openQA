# basic utility functions
#
# Copyright 2007 Bernhard M. Wiedemann
# Licensed for use, modification, distribution etc
# under the terms of GNU General Public License v2 or later

package awstandard;

use strict;
require 5.002;
use constant DAYSECS => 3600*24;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.60 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = 
qw(&awstandard_init &bmwround &bmwmod &awdiag &AWheader3 &AWheader2 &AWheader &AWtail &AWfocus 
&mon2id &gmdate &AWtime &AWisodate &AWisodatetime &AWisodatetime2 &AWreltime &safe_encode &html_encode &url_encode &file_content &set_file_content &awmax &awmin 
  );

use CGI ":standard";
use Time::HiRes qw(gettimeofday tv_interval);

our $style;
our $timezone;
our @month=qw(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec);
our %month=qw(Jan 1 Feb 2 Mar 3 Apr 4 May 5 Jun 6 Jul 7 Aug 8 Sep 9 Oct 10 Nov 11 Dec 12);
our @weekday=qw(Sun Mon Tue Wed Thu Fri Sat);
our @relationcolor=("", "firebrick", "OrangeRed", "orange", "grey", "navy", "RoyalBlue", "darkturquoise", "LimeGreen", "green");
our @statuscolor=qw(black black blue cyan red green orange green);
our $start_time;
our $customhtml;

sub awstandard_init() {
   my $alli=$ENV{REMOTE_USER};
   if($alli && $awaccess::remap_alli{$alli}) {
      $ENV{REMOTE_USER}=$alli=$awaccess::remap_alli{$alli};
   }
#   chdir $codedir;
   if(!defined($timezone)) {$timezone=0}
   $start_time=[gettimeofday()];
}
# free locks & other critical resources
sub awstandard_finish() {
}


sub bmwmod($$) { my($number,$mod)=@_; my $sign=($number <=> 0);
   my $off=50;
   return ((($number*$sign + $off)%$mod - $off) *$sign );
}

sub awdiag($) { my ($str)=@_;
   open(LOG, ">>", "/tmp/aw.log");
   print LOG (scalar localtime()." $str\n");
   close(LOG);
}

our %headerlinkmap=(imessage=>"BIM");

sub AWheader3($$;$) { my($title, $title2, $extra)=@_;
	my $links="";
	my $owncgi=$ENV{SCRIPT_NAME}||"";
   my $heads=[Link({-rel=>"icon", -href=>"/favicon.ico", -type=>"image/ico"}),Link({-rel=>"shortcut icon", -href=>"http://aw.lsmod.de/favicon.ico"})];
   if($extra) {push(@$heads,$extra);}
   push(@$heads,qq!<link rel="stylesheet" type="text/css" href="/code/css/tools/common.css" />!);
#   push(@$heads, "<title>$title</title>");
	$owncgi=~s!/cgi-bin/(?:modperl/)?!!;
	foreach my $item (qw(index.html tactical-live2 relations allirelations alliance system-info fleets imessage)) {
		my %h=(href=>$item);
		my $linktext=$headerlinkmap{$item}||$item;
		if($item eq $owncgi) {
			$h{class}='headeractive';
			$links.="|".span({-class=>"headeractive"},"&nbsp;".a(\%h,$linktext)." ");
			next;
		}
		$links.="|&nbsp;".a(\%h,$linktext)." ";
	}
	if($ENV{HTTP_AWPID}) {
		$links.="|&nbsp;".a({-href=>"relations?id=$ENV{HTTP_AWPID}"}, "self");
	}
	$links.=$customhtml||"";
	if(!$style) {$style='blue'}
   my $flag = autoEscape(0);
	local $^W=0; #disable warnings for next line
   my $retval=start_html(-title=>$title, -style=>"/code/css/tools/$style.css", 
	# -head=>qq!<link rel="icon" href="/favicon.ico" type="image/ico" />!).
	 -head=>$heads);
   autoEscape([$flag]);
   my $imsg="";
	return $retval.
#      img({-src=>"/images/greenbird_banner.png", -id=>"headlogo"}).
      div({-align=>'justify',-class=>'header'},
#a({href=>"index.html"}, "AW tools index").
	$links).
   "\n$imsg".a({-href=>"?"},h1($title2))."\n";
}
sub AWheader2($;$) { my($title,$extra)=@_; AWheader3($title, $title, $extra);}
sub AWheader($;$) { my($title,$extra)=@_; header(-connection=>"Keep-Alive", -keep_alive=>"timeout=15, max=99").AWheader2($title,$extra);}
sub AWtail() {
#   eval "awinput::awinput_finish()";
	my $t = sprintf("%.3f",tv_interval($start_time));
	return hr()."request took $t seconds".end_html();
}
sub AWfocus($) { my($elem)=@_;
    return
   qq'<script language="javascript" type="text/javascript">
     document.$elem.focus();
     document.$elem.select();
   </script>';
}

sub mon2id($) {my($m)=@_;
#        for(my $i=0; $i<12; $i++) {
#                if($m eq $month[$i]) {return $i}
#        }
        return $month{$m}-1;
}

# input: AW style time string
# output: UNIX timestamp
sub parseawdate($) {my($d)=@_;
        my @val;
        if(my @v=($d=~/(\d\d):(\d\d):(\d\d)\s-\s(\w{3})\s(\d+)/)) {
           @val=@v;
        } elsif(@v=($d=~/(\w{3})\s(\d+)\s-\s(\d\d):(\d\d):(\d\d)/)) {
           @val=@v[2,3,4,0,1];
        } else { return undef }
#if($d!~/(\d\d):(\d\d):(\d\d)\s-\s(\w{3})\s(\d+)/);
        my ($curmon,$year)=(gmtime())[4,5];
        my $mon=mon2id($val[3]);
        if($mon<$curmon-6){$year++}
        if($mon>$curmon+6){$year--}
        return timegm($val[2],$val[1],$val[0],$val[4], $mon, $year);
}

sub gmdate($) {
	my @a=gmtime($_[0]); $a[5]+=1900;
	return "$month[$a[4]] $a[3] $a[5]";
}

# input: UNIX epoch integer
# output: HTTP-conformant time string
sub HTTPdate($) {
   my ($t)=@_;
   my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday)=gmtime($t);
   $year+=1900;
   return sprintf("$weekday[$wday], %.2i $month[$mon] $year %.2i:%.2i:%.2i GMT", $mday, $hour, $min, $sec);
}

# input AW title string
# output timezone shift relative to UTC in seconds (e.g. CET=3600)
sub guesstimezone($) {my($title)=@_;
   my $utc=time();
   return undef unless $title=~m/(\d\d):(\d\d):(\d\d)/;
   my $localt=$1*3600+$2*60+$3;
   my $diff=$localt-($utc%86400);
   my $tzs=($diff+86400/2)%86400-86400/2;
   return($tzs-(($tzs+900)%(1800)-900)); # round to half hours
}

sub AWreltime($) { my($t)=@_;
   my $diff = $t-time();
   return sprintf("%.1fh %s",abs($diff)/3600,($diff>0?"from now":"ago"));
}
sub AWtime($) { my($t)=@_;
   my $tz=$timezone;
   if($tz>=0){$tz="+$tz"}
   return AWreltime($t)." = ". scalar gmtime($t)." GMT = ".scalar gmtime($t+3600*$timezone)." GMT$tz";
}

# input: UNIX timestamp
# input: ISO format date string (like 2005-12-31)
sub AWisodate($) { my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = gmtime($_[0]);
   sprintf("%i-%.2i-%.2i", $year+1900, $mon+1, $mday);
}

# input: UNIX timestamp
# input: ISO format date+time string (like 2005-12-31 23:59:59)
sub AWisodatetime($) { my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = gmtime($_[0]);
   sprintf("%i-%.2i-%.2i %.2i:%.2i:%.2i", $year+1900, $mon+1, $mday, $hour, $min, $sec);
}
sub AWisodatetime2($) { my($sec,$min,$hour,$mday,$mon,$year,$wday,$yday) = gmtime($_[0]);
   sprintf("%i-%.2i-%.2i %.2i:%.2i", $year+1900, $mon+1, $mday, $hour, $min);
}

sub urldecode { my($string) = @_;
# convert all '+' to ' '
   $string =~ s/\+/ /g;    
# Convert %XX from hex numbers to ASCII 
   $string =~ s/%([0-9a-fA-F][0-9a-fA-F])/pack("c",hex($1))/eg; 
   return($string);
}

sub safe_encode($) { my($name)=@_;
   $name||="";
   $name=~s/[^a-zA-Z0-9-]/"_".ord($&)/ge;
   return $name;
}
my %htmlcode=(
      "<"=>"&lt;",
      ">"=>"&gt;",
      "\""=>"&quot;",
   );
sub html_encode($) {
   return if not $_[0];
   $_[0]=~s/[<>"]/$htmlcode{$&}/g;
}
sub url_encode($) {
   return if not defined $_[0];
   my $x=shift;
   $x=~s/[^a-zA-Z0-9.-]/sprintf("%%%02x",ord($&))/ge;
   return $x;
}

sub file_content($) {my($fn)=@_;
   open(FCONTENT, "<", $fn) or return undef;
   local $/;
   my $result=<FCONTENT>;
   close(FCONTENT);
   return $result;
}
sub set_file_content($$) {my($fn,$data)=@_;
   open(my $fc, ">", $fn) or return undef;
   print $fc $data;
   close($fc);
}

sub awmax($$) {
   $_[0]>$_[1]?$_[0]:$_[1];
}
sub awmin($$) {
   $_[0]<$_[1]?$_[0]:$_[1];
}

1;
