#!/usr/bin/env perl
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
use warnings;
use Data::Dump;
use Getopt::Long;
use LWP::UserAgent;
Getopt::Long::Configure("no_ignore_case");
use Mojo::URL;

my $clientclass;
for my $i (qw/JSON::RPC::Legacy::Client JSON::RPC::Client/) {
    eval "use $i;";
    $clientclass = $i unless $@;
}
die $@ unless $clientclass;

use FindBin;
use lib "$FindBin::Bin/../lib";
use OpenQA::API::V1::Client;

my %options;

sub usage($) {
    my $r = shift;
    eval "use Pod::Usage; pod2usage($r);";
    if ($@) {
        die "cannot display help, install perl(Pod::Usage)\n";
    }
}

GetOptions(\%options,"from=s","fromv3","host=s","hostv3","dir=s","verbose|v","help|h",) or usage(1);

usage(1) unless @ARGV;
usage(1) unless exists $options{'from'};
$options{'dir'} ||= '/var/lib/openqa/factory/iso';

die "can't write $options{dir}\n" unless -w $options{dir};

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
$ua->env_proxy;

sub fixup_url($){
    my $host = shift;
    $host .= '/jsonrpc' unless $host =~ '/';
    $host = 'http://'.$host unless $host=~ '://';
    return $host;
}

$options{'host'} ||= 'localhost';

my $local;
my $local_url;
if ($options{hostv3}) {
    if ($options{'host'} !~ '/') {
        $local_url = Mojo::URL->new();
        $local_url->host($options{'host'});
        $local_url->scheme('http');
    }
    else {
        $local_url = Mojo::URL->new($options{'host'});
    }
    $local_url->path('/api/v1/jobs');
    $local = OpenQA::API::V1::Client->new(api => $local_url->host);

}
else {
    $local = new $clientclass;
    $local->prepare(fixup_url($options{'host'}), [qw/job_create/]) or die "$!\n";
}

my $remote;
my $remote_url;
if ($options{fromv3}) {
    if ($options{'from'} !~ '/') {
        $remote_url = Mojo::URL->new();
        $remote_url->host($options{'from'});
        $remote_url->scheme('http');
    }
    else {
        $remote_url = Mojo::URL->new($options{'from'});
    }
    $remote_url->path('/api/v1/jobs');
    $remote = OpenQA::API::V1::Client->new(api => $remote_url->host);

}
else {
    $remote = new $clientclass;
    $remote->prepare(fixup_url($options{'from'}), [qw/job_get/]) or die "$!\n";
}

if (my $name = shift @ARGV) {
    my $job;
    if ($options{fromv3}) {
        my $url = $remote_url->clone;
        $url->path("jobs/$name");
        my $tx = $remote->get($url);
        if ($tx->success) {
            if ($tx->success->code == 200) {
                $job = $tx->success->json->{job};
            }
            else {
                warn sprintf("unexpected return code: %s %s", $tx->success->code, $tx->success->message);
                exit 1;
            }
        }
        else {
            warn "failed to get job ", $tx->error;
            exit(1);
        }

    }
    else {
        $job = $remote->job_get($name);
    }
    dd $job if $options{verbose};
    my $dst = $job->{settings}->{ISO};
    $dst =~ s,.*/,,;
    $dst = join('/', $options{dir}, $dst);
    my $from;
    if ($options{fromv3}) {
        $from = $remote_url->clone;
        $from->path('/iso/'.$job->{settings}->{ISO});
        $from = $from->to_string;
    }
    else {
        $from = fixup_url($options{from});
        $from =~ s,^(http://[^/]*).*,$1,;
        $from .= '/openqa/factory/iso/'.$job->{settings}->{ISO};
    }
    print "downloading\n$from\nto\n$dst\n";
    my $r = $ua->mirror($from, $dst);
    unless ($r->is_success || $r->code == 304) {
        die "$name failed: ",$r->status_line, "\n";
    }
    if ($options{hostv3}) {
        warn "here";
        my $url = $local_url->clone;
        my @settings = %{$job->{settings}};
        for my $arg (@ARGV) {
            if ($arg =~ /([A-Z0-9]+)=([[:alnum:]+_-]+)/) {
                push @settings, $1, $2;
            }
            else {
                warn "arg $arg doesnt match";
            }
        }
        $url->query(@settings);
        my $tx = $local->post($url);
        if ($tx->success) {
            $r = $tx->success->json->{id};
        }
        else {
            warn "failed to create job ", $tx->error;
            exit(1);
        }
    }
    else {
        my @settings = map { sprintf("%s=%s", $_, $job->{settings}->{$_}) } sort keys %{$job->{settings}};
        $r = $local->job_create(@settings);
    }
    print "Created job #$r\n";
}

1;
# vim: set sw=4 et:
