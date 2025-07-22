# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::schedule;
use Mojo::Base 'OpenQA::CLI::monitor', -signatures;
use Term::ANSIColor qw(colored);

has description => 'Schedules a set of jobs (via "isos post" creating a schedule product)';
has usage => sub { OpenQA::CLI->_help('schedule') };
has post_url => sub { shift->url_for('isos') };

sub _create_jobs ($self, $client, $args, $param_file, $job_ids) {
    my $params = $self->parse_params($args, $param_file);
    my $tx = $client->build_tx(POST => $self->post_url, {}, form => $params);
    my $res = $self->retry_tx($client, $tx);
    return $res if $res != 0;
    my $json = $tx->res->json;
    push @$job_ids, $json->{id} if defined $json->{id} && ref $json->{id} eq '';
    push @$job_ids, @{$json->{ids}} if ref $json->{ids} eq 'ARRAY';
    if (my $job_count = @$job_ids) {
        my $host_url = Mojo::URL->new($self->host);
        say $job_count == 1 ? '1 job has been created:' : "$job_count jobs have been created:";
        say ' - ' . $host_url->clone->path("tests/$_") for @$job_ids;
    }
    return 0 unless my $error = $json->{error} // join("\n", map { $_->{error_message} } @{$json->{failed}});
    print STDERR colored(['red'], $error, "\n");
    return 1;
}

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(schedule => \@args, [], \my %options);

    @args = $self->decode_args(@args);
    my $client = $self->client($self->post_url);

    my @job_ids;
    my $create_res = $self->_create_jobs($client, \@args, $options{'param-file'}, \@job_ids);
    return $create_res if $create_res != 0 || !$options{monitor};
    return $self->_monitor_and_return($client, $options{follow}, $options{'poll-interval'}, \@job_ids);
}

1;
