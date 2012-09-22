package openqa;
use strict;
require 5.002;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 1.12 $ =~ /(\d+)/g;
@ISA = qw(Exporter);
@EXPORT = qw(
$prj $basedir $perldir $perlurl $app_title $app_subtitle
&parse_log &parse_log_to_stats &parse_log_to_hash &log_to_scriptpath &path_to_url &split_filename &resultname_to_log &resultname_to_url &is_authorized_rw &get_testimgs &get_waitimgs &get_clickimgs testimg &get_testwavs &running_log &clickimg &path_to_testname &cycle &sortkeys &syntax_highlight &first_run &data_name &parse_refimg_path &parse_refimg_name &back_log &running_state
);
use lib "/usr/share/openqa/cgi-bin/modules";
use awstandard;
our $basedir="/usr/lib";
our $prj="openqa";
our $perlurl="$prj/perl/autoinst";
our $perldir="$basedir/$perlurl";
our $hostname="openqa.opensuse.org";
our $app_title = 'openQA';
our $app_subtitle = 'openSUSE automated testing';

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

# find the full pathname to a given testrun-logfile and test name
sub log_to_scriptpath($$)
{ my($fn,$testname)=@_;
	open(my $fd, "<", $fn) or return undef;
	while(my $line=<$fd>) {
		next unless $line=~m/^(?:scheduling|starting) $testname (\S*)/;
		return $1;
	}
	return undef;
}

sub running_log($) {
	my ($name) = @_;
	my @runner = <$basedir/$prj/pool/[0-9]>;
	push(@runner, "$basedir/$prj/pool/manual");
	foreach my $path (@runner) {
		my $testfile = $path."/testname";
		open(my $fd, $testfile) || next ;
		my $rnam = <$fd>;
		chomp($rnam);
		close($fd);
		if ($name eq $rnam) {
			return $path."/";
		}
	}
	return "";
}

sub back_log($) {
	my ($name) = @_;
	my $backlogdir = "*";
	my @backlogs = <$basedir/$prj/backlog/$backlogdir/name>;
	foreach my $filepath (@backlogs) {
		my $path = $filepath;
		$path=~s/\/name$//;
		open(my $fd, $filepath) || next ;
		my $rnam = <$fd>;
		chomp($rnam);
		close($fd);
		if ($name eq $rnam) {
			return $path."/";
		}
	}
	return "";
}

sub running_state($) {
	my ($name) = @_;
	my $dir = running_log($name);
	my $pid = file_content("$dir/os-autoinst.pid");
	chomp($pid);
	my $state = file_content("/proc/$pid/status") || "";
	$state=~m/^State:\s+(\w)\s/m;
	$state = $1;
	return ($state eq "T")?0:1;
}

# get testname by name or path
sub path_to_testname($) {
	my $fn=shift;
	$fn=~s%\.autoinst\.txt$%%;
	$fn=~s%\.ogv$%%;
	$fn=~s%.*/%%;
	return $fn;
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
	return (@a);
}

sub resultname_to_log($)
{ "$basedir/$prj/video/$_[0].ogv.autoinst.txt"; 
}
sub resultname_to_url($)
{ "http://$hostname/results/$_[0]"; 
}

sub is_authorized_rw()
{
	my $ip=$ENV{REMOTE_ADDR};
	return 1 if($ip eq "195.135.221.2" || $ip eq "78.46.32.14" || $ip=~m/^2001:6f8:11fc:/ || $ip eq "2001:6f8:900:9b2::2" || $ip eq "2a01:4f8:100:9041::2" || $ip=~m/^10\./ || $ip eq "127.0.0.1" || $ip eq "::1");
	return 0;
}

sub get_testimgs($)
{ my $name=shift;
	my @a=<$perldir/testimgs/$name-*>; # needs to be in list context
	return @a;
}

sub get_waitimgs($)
{ my $name=shift;
	my @a=<$perldir/waitimgs/$name-*>; # needs to be in list context
	return @a;
}

sub get_clickimgs($)
{ my $name=shift;
	my @a=<$perldir/waitimgs/click/$name-*>; # needs to be in list context
	return @a;
}

sub get_testwavs($)
{ my $name=shift;
	my @a=<$perldir/audio/$name-*>; # needs to be in list context
	return @a;
}

sub testimg($)
{ my $name=shift;
	return "$perldir/testimgs/$name";
}

sub clickimg($)
{ my $name=shift;
	return "$perldir/waitimgs/click/$name";
}


our $table_row_style = 0;
sub cycle(;$) {
	my $cset = shift||0;
	if($cset == 1) {
		$table_row_style = 0;
		return;
	}
	if($cset != 2) { # 2 means read without toggle
		$table_row_style^=1; # toggle state
	}
	return $table_row_style?'odd':'even';
}

our $loop_first_run = 1;
sub first_run(;$) {
	if(shift) {
		$loop_first_run = 1;
		return;
	}
	if($loop_first_run) {
		$loop_first_run = 0;
		return 1;
	}
	else {
		return 0;
	}
}

sub sortkeys($$) {
	my $options = shift;
	my $sortname = shift;
	my $suffix = "";
	$suffix .= ".".$options->{'sort'}.(defined($options->{'hours'})?"&amp;hours=".$options->{'hours'}:"");
	$suffix .= (defined $options->{'match'})?"&amp;match=".$options->{'match'}:"";
	$suffix .= ($options->{'ib'})?"&amp;ib=on":"";
	my $dn_url = "?sort=-".$sortname.$suffix;
	my $up_url = "?sort=".$sortname.$suffix;
	return '<a rel="nofollow" href="'.$dn_url.'"><img src="/images/ico_arrow_dn.gif" style="border:0" alt="sort dn" /></a><a rel="nofollow" href="'.$up_url.'"><img src="/images/ico_arrow_up.gif" style="border:0" alt="sort up" /></a>';
}

sub syntax_highlight($)
{
	my $script=shift;
	$script=~s{^sub is_applicable}{# this function decides if the test shall run\n$&}m;
	$script=~s{^sub run}{# this part contains the steps to run this test\n$&}m;
	$script=~s{^sub checklist}{# this part contains known hash values of good or bad results\n$&}m;
	eval "require Perl::Tidy;" or return "<pre>$script</pre>";
	push(@ARGV,"-html", "-css=/dev/null");
	my @out;
	Perl::Tidy::perltidy(
		source => \$script,
		destination => \@out,
	);
	my $out=join("",@out);
	#$out=~s/.*<body>//s;
	$out=~s/.*<!-- contents of filename: perltidy -->//s;
	$out=~s{</body>.*}{}s;
	return $out;
}

sub data_name($) {
	$_[0]=~m/^.*\/(.*)\.\w\w\w(?:\.gz)?$/;
	return $1;
}

sub parse_refimg_path($) {
	$_[0]=~m/.*\/(\w+)-(\d+)-(\d+)-(\w+)\.ppm/;
	return ($1,$2,$3,$4);
}
sub parse_refimg_name($) {
	my($testmodule,$screenshot,$n,$result)=parse_refimg_path($_[0]);
	return {name => "$testmodule-$screenshot-$n-$result", result => $result};
}

1;
