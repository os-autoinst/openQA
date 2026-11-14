# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI::workers;
use Mojo::Base 'OpenQA::Command', -signatures;

use List::Util 'min';

has description => 'Audit worker and host utilization';
has usage => sub { OpenQA::CLI->_help('workers') };

sub _idle_days ($s) {
    return undef unless $s->{last_job_finished};
    return int(($s->{idle_seconds} // 0) / 86400);
}

sub _dormant ($s, $days) {
    return 1 unless $s->{last_job_finished};
    return _idle_days($s) >= $days;
}

sub _trunc ($s, $n) { $s = '' unless defined $s; length($s) > $n ? substr($s, 0, $n) : $s }

sub _print_hosts ($self, $hosts, $days) {
    printf "%-22s %-13s %-22s %-21s %s\n", 'HOST', 'SLOTS(ON/TOT)', 'CLASSES', 'LAST JOB', 'IDLE';
    for my $host (sort keys %$hosts) {
        my $s = $hosts->{$host};
        my $idle = _idle_days($s);
        my $idle_str = $s->{last_job_finished} ? "${idle}d" : 'never';
        my $flag = _dormant($s, $days) ? ' <= IDLE' : '';
        printf "%-22s %-13s %-22s %-21s %s%s\n",
          $host,
          "$s->{online_instances}/$s->{total_instances}",
          _trunc(join(',', @{$s->{worker_classes}}), 22),
          _trunc($s->{last_job_finished} // '-', 20),
          $idle_str,
          $flag;
    }
}

sub command ($self, @args) {
    die $self->usage unless OpenQA::CLI::get_opt(workers => \@args, [], \my %options);
    @args = $self->decode_args(@args);
    my $days = $options{'unused-days'} // 14;

    my $url = $self->url_for('worker_hosts');
    my $client = $self->client($url);
    my $tx = $client->build_tx(GET => $url);
    my $res = $self->retry_tx($client, $tx);
    return $res if $res != 0;

    my $hosts = $tx->res->json->{hosts} // {};
    _print_hosts($self, $hosts, $days);
    return 0;
}

1;
