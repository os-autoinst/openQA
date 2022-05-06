# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::clone;
use Mojo::Base 'OpenQA::Command', -signatures;

use Mojo::Util qw(getopt);
use OpenQA::Script::CloneJob;
use OpenQA::Utils 'assetdir';

has description => 'Creates a new job based on an existing job';
has usage => sub ($self) { $self->extract_usage };

sub command ($self, @args) {
    die $self->usage
      unless getopt \@args,
      'skip-download' => \my $skip_download,
      'dir=s' => \(my $dir = assetdir()),
      'within-instance' => \my $within_instance;

    @args = $self->decode_args(@args);
    die $self->usage unless my $job = shift @args;

    my ($from, $jobid) = split_jobid($job);
    if ($within_instance) {
        $self->host($from);
        $skip_download = 1;
    }

    clone_jobs($jobid,
        {from => $self->host, args => \@args, dir => $dir, 'skip-download' => $skip_download, host => $self->host, apikey => $self->apikey, apisecret => $self->apisecret});

    return 0;
}

1;

=encoding utf8

=head1 SYNOPSIS

  Usage: openqa-cli clone [OPTIONS] JOB [KEY=[VALUE] ...]

    # Clone a job to openqa.opensuse.org
    openqa-cli clone --osd http://openqa.example.com/t416081 FOO=bar

    # Clone a job to the same instance
    openqa-cli clone --within-instance https://openqa.opensuse.org/t2330754

  Options:
        --apibase <path>           API base, defaults to /api/v1
        --apikey <key>             API key
        --apisecret <secret>       API secret
        --host <host>              Target host, defaults to http://localhost
    -h, --help                     Show this summary of available options
        --osd                      Set target host to http://openqa.suse.de
        --o3                       Set target host to https://openqa.opensuse.org
        --dir                      Specify the directory to store test assets,
                                   defaults to $OPENQA_SHAREDIR/factory
        --skip-download            Do NOT download assets. You need to ensure all
                                   required assets are provided yourself.
        --within-instance          Set target host based on JOB

=cut
