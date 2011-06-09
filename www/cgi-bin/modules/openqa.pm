package openqa;
use strict;
require 5.002;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = qw(
$prj $basedir $perldir
&parse_log &parse_log_to_stats &parse_log_to_hash &path_to_url &split_filename &get_header_footer &resultname_to_log &resultname_to_url &is_authorized_rw &get_testimgs testimg
);
use lib "/srv/www/cgi-bin/modules";
use awstandard;
our $basedir="/space/geekotest";
our $prj="opensuse";
our $perldir="$basedir/$prj/perl/autoinst";
our $hostname="openqa.opensuse.org";

sub parse_log($) { my($fn)=@_;
	open(my $fd, "<", $fn) || return;
	seek($fd, -4095, 2);
	my $logdata;
	read($fd,$logdata,100000);
	close($fd);

	# assume first log line is splashscreen:
	return () unless $logdata=~s/.*====\n//s;
	my @lines=map {[split(": ")]} split("\n",$logdata);
	return @lines;
}

sub parse_log_to_stats($) { my($lines)=@_;
	my %stats;
	foreach my $entry (@$lines) {
		my $result=$entry->[1];
		$result=~s/\s.*//;
		$stats{$result}++;
	}
	return \%stats;
}
sub parse_log_to_hash($) { my($lines)=@_;
	my %results=();
	foreach my $entry (@$lines) {
		$results{$entry->[0]}=$entry->[1];
	}
	return \%results;
}

sub imgdir($) { my $fn=shift;
	$fn=~s%\.autoinst\.txt$%%;
	$fn=~s%\.ogv$%%;
	"$basedir/$prj/testresults/$fn";
}
sub path_to_url($) { my($fn)=@_;
	my $url=$fn;
	$url=~s%^$basedir%%; # strip path to make relative URL
	return $url;
}

sub path_to_ogvlink($) { my($fn)=@_;
	my $url=path_to_url($fn);
	$url=~s%\.autoinst\.txt$%%;
	$url=~s%^(.*)%<a href="$1"><img width="23" height="23" src="/images/video.png" alt="ogv" title="ogg/theora video of this testrun"/></a>%;
	return $url;
}
sub path_to_detailurl($) { my($fn)=@_;
	my $url=path_to_url($fn);
	$url=~s%^/$prj/video(.*).ogv.autoinst.txt%/results$1%;
	return $url;
}
sub path_to_detaillink($) { my($fn)=@_;
	my $url=path_to_detailurl($fn);
	$url=qq(<a href="$url"><img width="23" height="23" src="/images/details.png" alt="details" title="test result details"/></a>);
	return $url;
}
sub path_to_loglink($) { my($fn)=@_;
	my $url=path_to_url($fn);
	return qq%<a href="$url"><img width="23" height="23" src="/images/log.png" alt="log" title="complete log of this testrun"/></a>%;
}
sub split_filename($) { my($fn)=@_;
	my $origfn=$fn;
	$fn=~s%\.autoinst\.txt$%%; # strip suffix
	$fn=~s%\.ogv$%%; # strip suffix
	$fn=~s%.*/%%; # strip path

	# since we want to split at "-", this should not appear within fields
	$fn=~s/Promo-DVD/DVD_Promo/;
	$fn=~s/DVD-Biarch-i586-x86_64/DVD_Biarch-i586+x86_64/;
	$fn=~s/-LiveCD/_LiveCD/; # belongs to KDE/GNOME, so protect from split
	$fn=~s/(SLE.)-(\d+)-(SP|G)/$1_$2_$3/;
	my @a=split("-",$fn);
	$a[3]=~s/Build//;
	$a[4]||=""; # extrainfo is optional
	my $links=path_to_detaillink($origfn)." ".path_to_ogvlink($origfn);
	return ($links, @a);
}

sub get_header_footer(;$)
{	my ($title)=@_;
	my $templatedir="/srv/www/htdocs/template";
	my $header=file_content("$templatedir/header.html");
	$title=($title? " &gt; $title" : "");
	$header=~s{<!-- CURRENTLOCATION -->}{$title};
	$header=file_content("$templatedir/header0.html").$header.file_content("$templatedir/header-cgi.html");
	my $footer=file_content("$templatedir/footer.html");
	return ($header,$footer);
}

sub resultname_to_log($)
{ "/$prj/video/$_[0].ogv.autoinst.txt"; 
}
sub resultname_to_url($)
{ "http://$hostname/results/$_[0]"; 
}

sub is_authorized_rw()
{
	my $ip=$ENV{REMOTE_ADDR};
	return 1 if($ip eq "195.135.221.2" || $ip eq "78.46.32.14" || $ip=~m/^2001:6f8:11fc:/ || $ip eq "2001:6f8:900:9b2::2" || $ip=~m/^10\./);
	return 0;
}

sub get_testimgs($)
{ my $name=shift;
	my @a=<$perldir/testimgs/$name-*>; # needs to be in list context
	return @a;
}

sub testimg($)
{ my $name=shift;
	return "$perldir/testimgs/$name";
}

1;
