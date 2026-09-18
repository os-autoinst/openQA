# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::schedule;
use Mojo::Base 'OpenQA::CLI::monitor', -signatures;
use Term::ANSIColor qw(colored);

has description => 'Schedules a set of jobs (via "isos post" creating a schedule product)';
has usage => sub { OpenQA::CLI->_help('schedule') };
has post_url => sub { shift->url_for('isos') };

sub _create_jobs ($self, $client, $args, $options, $job_ids) {
    my $params = $self->parse_params($args, $options->{'param-file'});
    my $tx = $client->build_tx(POST => $self->post_url, {}, form => $params);
    my $res = $self->retry_tx($client, $tx);
    return $res if $res != 0;
    my $json = $tx->res->json;
    my $scheduled_product_id = $json->{scheduled_product_id};
    push @$job_ids, $json->{id} if defined $json->{id} && ref $json->{id} eq '';
    push @$job_ids, @{$json->{ids}} if ref $json->{ids} eq 'ARRAY';
    if (my $job_count = @$job_ids) {
        my $host_url = Mojo::URL->new($self->host);
        say $job_count == 1 ? '1 job has been created:' : "$job_count jobs have been created:";
        say ' - ' . $host_url->clone->path("tests/$_") for @$job_ids;
    }
    my $error = $self->_error_from_json($json);
    $error = $self->_wait_for_jobs($client, $options->{'poll-interval'}, $scheduled_product_id, $job_ids)
      if !$error && !@$job_ids && $options->{monitor};
    return 0 unless $error;
    print STDERR colored(['red'], $error, "\n");
    return 1;
}

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(schedule => \@args, [], \my %options);

    @args = $self->decode_args(@args);
    my $client = $self->client($self->post_url);

    my @job_ids;
    my $poll_interval = ($options{'poll-interval'} //= 1);
    my $create_res = $self->_create_jobs($client, \@args, \%options, \@job_ids);
    return $create_res if $create_res != 0 || !$options{monitor};
    return $self->_monitor_and_return($client, $options{follow}, $poll_interval, \@job_ids);
}

1;
