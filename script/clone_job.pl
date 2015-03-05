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

clone_job.pl [OPTIONS] JOBID [KEY=[VALUE] ...]

=head1 OPTIONS

=over 4

=item B<--host> HOST

connect to specified host

=item B<--from> HOST

get job from specified host

=item B<--dir> DIR

specify directory where the iso is stored (default /var/lib/openqa/factory/iso/)

=item B<--apikey> <value>

specify the public key needed for API authentication

=item B<--apisecret> <value>

specify the secret key needed for API authentication

=item B<--help, -h>

print help

=back

=head1 DESCRIPTION

Clone job from another instance. Downloads all assets associated
with the job. Optionally settings can be modified.

clone_job.pl --from https://openqa.opensuse.org 42

clone_job.pl --from https://openqa.opensuse.org --host openqa.example.com 42

clone_job.pl --from localhost --host localhost 42 MAKETESTSNAPSHOTS=1 FOOBAR=

=cut

use strict;
use warnings;
use Data::Dump qw/dd pp/;
use Getopt::Long;
use LWP::UserAgent;
Getopt::Long::Configure("no_ignore_case");
use Mojo::URL;
use JSON;

my $clientclass;
for my $i (qw/JSON::RPC::Legacy::Client JSON::RPC::Client/) {
    eval "use $i;";
    $clientclass = $i unless $@;
}
die $@ unless $clientclass;

use FindBin;
use lib "$FindBin::Bin/../lib";
use OpenQA::Client;

my %options;

sub usage($) {
    my $r = shift;
    eval "use Pod::Usage; pod2usage($r);";
    if ($@) {
        die "cannot display help, install perl(Pod::Usage)\n";
    }
}

GetOptions(\%options,"from=s","host=s","dir=s","apikey:s","apisecret:s","verbose|v","help|h",) or usage(1);

usage(1) unless @ARGV;
usage(1) unless exists $options{'from'};

my $jobid = shift @ARGV || die "missing jobid\n";

$options{'dir'} ||= '/var/lib/openqa/factory';

die "can't write $options{dir}\n" unless -w $options{dir}.'/iso';

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
if ($options{'host'} !~ '/') {
    $local_url = Mojo::URL->new();
    $local_url->host($options{'host'});
    $local_url->scheme('http');
}
else {
    $local_url = Mojo::URL->new($options{'host'});
}
$local_url->path('/api/v1/jobs');
$local = OpenQA::Client->new(
    api => $local_url->host,
    apikey => $options{'apikey'},
    apisecret => $options{'apisecret'}
);

my $remote;
my $remote_url;
if ($options{'from'} !~ '/') {
    $remote_url = Mojo::URL->new();
    $remote_url->host($options{'from'});
    $remote_url->scheme('http');
}
else {
    $remote_url = Mojo::URL->new($options{'from'});
}
$remote_url->path('/api/v1/jobs');
$remote = OpenQA::Client->new(api => $remote_url->host);

if ($jobid) {
    my $job;
    my $url = $remote_url->clone;
    $url->path("jobs/$jobid");
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
        my $err = $tx->error;
        warn "failed to get job: $err->{code} $err->{message}";
        exit 1;
    }

    print JSON->new->pretty->encode($job) if ($options{verbose});

    for my $type (keys %{$job->{assets}}) {
        next if $type eq 'repo'; # we can't download repos
        for my $file (@{$job->{assets}->{$type}}) {
            my $dst = $file;
            $dst =~ s,.*/,,;
            $dst = join('/', $options{dir}, $type, $dst);
            my $from = $remote_url->clone;
            $from->path(sprintf '/tests/%d/asset/%s/%s', $jobid, $type, $file);
            $from = $from->to_string;

            print "downloading\n$from\nto\n$dst\n";
            my $r = $ua->mirror($from, $dst);
            unless ($r->is_success || $r->code == 304) {
                die "$jobid failed: ",$r->status_line, "\n";
            }
        }
    }

    $url = $local_url->clone;
    my %settings = %{$job->{settings}};
    delete $settings{NAME}; # usually autocreated
    for my $arg (@ARGV) {
        if ($arg =~ /([A-Z0-9_]+)=(.*)/) {
            if ($2) {
                $settings{$1} = $2;
            }
            else {
                delete $settings{$1};
            }
        }
        else {
            warn "arg $arg doesn't match";
        }
    }
    print JSON->new->pretty->encode(\%settings) if ($options{verbose});
    $url->query(%settings);
    $tx = $local->post($url);
    if ($tx->success) {
        my $r = $tx->success->json->{id};
        if ($r) {
            print "Created job #$r\n";
        }
        else {
            print "job not created. duplicate?\n";
        }
    }
    else {
        die "failed to create job: ", pp( $tx->res->body );
    }
}

1;
# vim: set sw=4 et:
