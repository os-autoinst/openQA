# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::archive;
use Mojo::Base 'OpenQA::Command', -signatures;

has description => 'Download assets and test results from a job';
has usage => sub { OpenQA::CLI->_help('archive') };

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(archive => \@args, [], \my %options);

    @args = $self->decode_args(@args);
    die $self->usage unless my $job = shift @args;
    die $self->usage unless my $path = shift @args;

    my $url = $self->url_for("jobs/$job/details");
    my $client = $self->client($url);
    $client->archive->run(
        {
            url => $url,
            archive => $path,
            'with-thumbnails' => $options{'with-thumbnails'},
            'asset-size-limit' => $options{'asset-size-limit'}});

    return 0;
}

1;
