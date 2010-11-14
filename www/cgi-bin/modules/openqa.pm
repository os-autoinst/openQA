package openqa;
use strict;
require 5.002;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = qw(
$basedir
&parse_log &path_to_url &split_filename &get_header_footer
);
use lib "/srv/www/cgi-bin/modules";
use awstandard;
our $basedir="/space/geekotest";

sub parse_log($) { my($fn)=@_;
	open(my $fd, "<", $fn) || return;
	seek($fd, -4095, 2);
	my $logdata;
	read($fd,$logdata,100000);
	close($fd);

	# assume first log line is splashscreen:
	$logdata=~s/.*(splashscreen:)/$1/s;
	my @lines=map {[split(": ")]} split("\n",$logdata);
	return @lines;
}

sub imgdir($) { my $fn=shift;
	$fn=~s%\.autoinst\.txt$%%;
	$fn=~s%\.ogv$%%;
	"$basedir/opensuse/testresults/$fn";
}
sub path_to_url($) { my($fn)=@_;
	my $url=$fn;
	$url=~s%^$basedir%%; # strip path to make relative URL
	return $url;
}

sub path_to_ogvlink($) { my($fn)=@_;
	my $url=path_to_url($fn);
	$url=~s%\.autoinst\.txt$%%;
	$url=~s%^(.*)%<a href="$1"><img src="/images/video.png" alt="ogv" title="ogg/theora video of this testrun"/></a>%;
	return $url;
}
sub path_to_detailurl($) { my($fn)=@_;
	my $url=path_to_url($fn);
	$url=~s%^/opensuse/video(.*).ogv.autoinst.txt%/cgi-bin/resultdetails$1%;
	return $url;
}
sub path_to_detaillink($) { my($fn)=@_;
	my $url=path_to_detailurl($fn);
	$url=qq(<a href="$url"><img src="/images/details.png" alt="details" title="test result details"/></a>);
	return $url;
}
sub path_to_loglink($) { my($fn)=@_;
	my $url=path_to_url($fn);
	$url=~s%^(.*)%<a href="$1"><img src="/images/log.png" alt="log" title="complete log of this testrun"/></a>%;
	return $url;
}
sub split_filename($) { my($fn)=@_;
	my $origfn=$fn;
	$fn=~s%\.autoinst\.txt$%%; # strip suffix
	$fn=~s%\.ogv$%%; # strip suffix
	$fn=~s%.*/%%; # strip path
	$fn=~s/-LiveCD/xLiveCD/; # belongs to KDE/GNOME, so protect from split
	my @a=split("-",$fn);
	$a[1]=~s/xLiveCD/-LiveCD/;
	$a[3]=~s/Build//;
	$a[4]||=""; # extrainfo is optional
	my $links=path_to_detaillink($origfn)." ".path_to_ogvlink($origfn)." ".path_to_loglink($origfn);
	return ($links, @a);
}

sub get_header_footer()
{
	my $templatedir="/srv/www/htdocs/template";
	my $header=file_content("$templatedir/header.html");
	my $footer=file_content("$templatedir/footer.html");
	return ($header,$footer);
}

1;
