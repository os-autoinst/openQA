# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::reservation;
use Mojo::Base 'OpenQA::Command', -signatures;

has description => 'Manage worker reservations';
has usage => sub { OpenQA::CLI->_help('reservation') };

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(reservation => \@args, [], \my %options);
    @args = $self->decode_args(@args);
    die $self->usage unless my $first = shift @args;
    my ($action, $workerid);
    if ($first eq 'extend') {
        $action = 'extend';
        die $self->usage unless $workerid = shift @args;
    }
    else {
        $workerid = $first;
        $action = $options{release} ? 'release' : 'reserve';
    }
    my $host = $options{'worker-host'};
    die $self->usage unless defined $workerid xor defined $host;
    my $url = $host ? $self->url_for("worker_hosts/$host/reservation") : $self->url_for("workers/$workerid/reservation");
    $url = $self->url_for("workers/$workerid/reservation/extend") if $action eq 'extend';
    my $client = $self->client($url);
    my $tx;
    if ($action eq 'release') {
        $tx = $client->build_tx(DELETE => $url);
    }
    elsif ($action eq 'extend') {
        my %params;
        my $by = $options{by} // $options{duration};
        die "An extension duration (via --by) is required\n" unless defined $by;
        $params{by} = $by;
        $tx = $client->build_tx(POST => $url, form => \%params);
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
