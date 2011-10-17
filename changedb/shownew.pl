#!/usr/bin/perl -w
use strict;
use Getopt::Long;
use changedb;

my @options=(qw"from=s to=s help|h|?");
my %options=(
	"from"=>"10d" # last 10 days
);

if(!GetOptions(\%options, @options) || (@ARGV && $ARGV[0] ne "")) {die "invalid option @ARGV\n"}
my $timefrom=rel_time($options{from});
my $timeto=rel_time($options{to});

foreach_change(sub{
		my($e,$buildid)=@_;
		my($time,$build)=split(" ",$buildid);
		return if $timefrom && $time<$timefrom;
		return if $timeto && $time>$timeto;
		print "$time $build $e\n";
	});

