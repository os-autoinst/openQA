# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::archive;
use Mojo::Base 'OpenQA::Command';

use Mojo::Util qw(getopt);

has description => 'Download assets and test results from a job';
has usage => sub { shift->extract_usage };

sub command {
    my ($self, @args) = @_;

    die $self->usage
      unless getopt \@args,
      'l|asset-size-limit=i' => \(my $limit),
      't|with-thumbnails' => \my $thumbnails;

    @args = $self->decode_args(@args);
    die $self->usage unless my $job = shift @args;
    die $self->usage unless my $path = shift @args;

    my $url = $self->url_for("jobs/$job/details");
    my $client = $self->client($url);
    $client->archive->run(
        {url => $url, archive => $path, 'with-thumbnails' => $thumbnails, 'asset-size-limit' => $limit});

    return 0;
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli archive [OPTIONS] JOB PATH

    # Download assets and test results from OSD to /tmp/job_416081
    openqa-cli archive --osd 416081 /tmp/job_416081

    # Download assets and test results from arbitrary host
    openqa-cli archive --host http://openqa.example.com 407 /tmp/foo

    # Download assets and test results from localhost (including thumbnails and
    # very large assets)
    openqa-cli archive -l 1048576000 -t 408 /tmp/bar

  Options:
        --apibase <path>           API base, defaults to /api/v1
        --apikey <key>             API key
        --apisecret <secret>       API secret
        --host <host>              Target host, defaults to http://localhost
    -h, --help                     Show this summary of available options
    -l, --asset-size-limit <num>   Asset size limit in bytes
        --osd                      Set target host to http://openqa.suse.de
        --o3                       Set target host to https://openqa.opensuse.org
    -t, --with-thumbnails          Download thumbnails as well

=cut
