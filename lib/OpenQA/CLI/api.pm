# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::api;
use Mojo::Base 'OpenQA::Command', -signatures;

use Mojo::File 'path';
use Mojo::JSON qw(decode_json);
use OpenQA::Constants qw(JOBS_OVERVIEW_SEARCH_CRITERIA);

has description => 'Issue an arbitrary request to the API';
has usage => sub {
    my $search_criteria = join(', ', JOBS_OVERVIEW_SEARCH_CRITERIA);
    OpenQA::CLI->_help('api') =~ s/\$search_criteria/$search_criteria/r;
};

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(api => \@args, [], \my %options);

    @args = $self->decode_args(@args);
    die $self->usage unless my $path = shift @args;
    my $data_file = $options{'data-file'};
    my $data = $options{data} // '';
    $data = $data_file eq '-' ? $self->data_from_stdin : path($data_file)->slurp if $data_file;

    my $params = $options{form} ? decode_json($data) : $self->parse_params(\@args, $options{'param-file'});
    my @data = keys %$params ? (form => $params) : ($data);

    my $headers = $self->parse_headers(@{$options{header}});
    $headers->{Accept} //= 'application/json';
    $headers->{'Content-Type'} = 'application/json' if $options{json};

    my $url = $self->url_for($path);
    my $client = $self->client($url);
    my $tx = $client->build_tx($options{method} // 'GET', $url, $headers, @data);
    $self->retry_tx($client, $tx, $options{retries});
}

1;
