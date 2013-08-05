#!/usr/bin/perl -w
# Copyright (c) 2013 SUSE Linux Products GmbH
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.

=head1 clone_job

clone_job.pl - clone job from remote QA instance

=head1 SYNOPSIS

clone_job.pl [OPTIONS] JOBS...

=head1 OPTIONS

=over 4

=item B<--host> HOST

connect to specified host

=item B<--from> HOST

get job from specified host

=item B<--dir> DIR

specify directory where the iso is stored (default /var/lib/openqa/factory/iso/)

=item B<--help, -h>

print help

=back

=head1 DESCRIPTION

lorem ipsum ...

=cut

use strict;
use Data::Dump;
use Getopt::Long;
use JSON::RPC::Client;
use LWP::UserAgent;
Getopt::Long::Configure("no_ignore_case");

my %options;

sub usage($) {
	my $r = shift;
	eval "use Pod::Usage; pod2usage($r);";
	if ($@) {
		die "cannot display help, install perl(Pod::Usage)\n";
	}
}

GetOptions(
	\%options,
	"from=s",
	"host=s",
	"dir=s",
	"verbose|v",
	"help|h",
) or usage(1);

usage(1) unless @ARGV;
usage(1) unless exists $options{'from'};
$options{'dir'} ||= '/var/lib/openqa/factory/iso';

die "can't write $options{dir}\n" unless -w $options{dir};

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->env_proxy;

sub fixup_url($)
{
	my $host = shift;
	$host .= '/jsonrpc' unless $host =~ '/';
	$host = 'http://'.$host unless $host=~ '://';
	return $host;
}

$options{'host'} ||= 'localhost';

my $local = new JSON::RPC::Client;
my $remote = new JSON::RPC::Client;

$options{'host'} = fixup_url($options{'host'});
$options{'from'} = fixup_url($options{'from'});

$local->prepare($options{'host'}, [qw/job_create/]) or die "$!\n";
$remote->prepare($options{'from'}, [qw/job_get/]) or die "$!\n";
while (my $name = shift @ARGV) {
	my $job = $remote->job_get($name);
	dd $job if $options{verbose};
	my $dst = $job->{settings}->{ISO};
	$dst =~ s,.*/,,;
	$dst = join('/', $options{dir}, $dst);
	my $from = $options{from};
	$from =~ s,^(http://[^/]*).*,$1,;
	$from .= '/openqa/factory/iso/'.$job->{settings}->{ISO};
	print "downloading\n$from\nto\n$dst\n";
	my $r = $ua->mirror($from, $dst);
	unless ($r->is_success || $r->code == 304) {
		print STDERR "$name failed: ",$r->status_line, "\n"; 
		next;
	}
	my @settings = map { sprintf("%s=%s", $_, $job->{settings}->{$_}) } sort keys %{$job->{settings}};
	$r = $local->job_create(@settings);
	print "Created job #$r\n";
}

1;
