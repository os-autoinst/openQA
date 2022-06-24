# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Controller::Influxdb;
use Mojo::Base 'Mojolicious::Controller', -signatures;

sub minion ($self) {
    my $app = $self->app;
    my $stats = $app->minion->stats;
    my $jobs = {
        active => $stats->{active_jobs},
        delayed => $stats->{delayed_jobs},
        failed => $stats->{failed_jobs},
        inactive => $stats->{inactive_jobs}};
    my $workers = {
        registered => $stats->{workers},
        active => $stats->{active_workers},
        inactive => $stats->{inactive_workers}};

    my $url = $self->req->url->base->to_string;
    my $text = '';
    $text .= _output_measure($url, 'openqa_minion_jobs', $jobs);
    $text .= _output_measure($url, 'openqa_minion_workers', $workers);

    my $metrics = $app->cache->metrics;
    my $bytes = $metrics->{download_rate};
    $text .= "openqa_download_rate,url=$url bytes=${bytes}i\n" if defined $bytes;

    $self->render(text => $text);
}

sub _output_measure ($url, $key, $states) {
    my $line = "$key,url=$url ";
    $line .= join(',', map { "$_=$states->{$_}i" } sort keys %$states);
    return $line . "\n";
}

1;
