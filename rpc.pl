#!/usr/bin/perl -w

use strict;
use JSON::RPC::Client;
use Data::Dump;

my $client = new JSON::RPC::Client;
my $port = 80;

my $url = "http://openqa.tanana.suse.de:$port/jsonrpc";

my %cmds = map { $_ => 0 } (qw/
	list_jobs
	/);
for (qw/
	echo
	job_delete
	/) {
	$cmds{$_} = 1;
}
$cmds{job_set_prio} = 2;
$cmds{job_create} = 99;

$client->prepare($url, [keys %cmds]) or die "$!\n";
while (my $cmd = shift @ARGV) {
	unless (exists $cmds{$cmd}) {
		warn "invalid command $cmd";
		next;
	}
	my @args;
	@args = splice(@ARGV,0,$cmds{$cmd}) if $cmds{$cmd};
	printf "calling %s(%s)\n", $cmd, join(', ', @args);
	my $ret;
	eval qq{
		\$ret = \$client->$cmd(\@args);
	};
	die ">>> $@ <<<\n" if ($@);
	dd $ret;
}

1;
