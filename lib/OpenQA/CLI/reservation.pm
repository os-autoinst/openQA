# Copyright 2026 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::reservation;
use Mojo::Base 'OpenQA::Command', -signatures;

has description => 'Manage worker reservations';
has usage => sub { OpenQA::CLI->_help('reservation') };

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(reservation => \@args, [], \my %options);

    @args = $self->decode_args(@args);
    die $self->usage unless my $workerid = shift @args;

    my $url = $self->url_for("workers/$workerid/reservation");
    my $client = $self->client($url);

    my $tx;
    if ($options{release}) {
        $tx = $client->build_tx(DELETE => $url);
    }
    else {
        my %params;
        $params{comment} = $options{comment} if defined $options{comment};
        $params{duration} = $options{duration} if defined $options{duration};
        $params{worker_class} = $options{class} if defined $options{class};
        $params{force} = 1 if $options{force};

        $tx = $client->build_tx(POST => $url, form => \%params);
    }

    return $self->retry_tx($client, $tx);
}

1;
