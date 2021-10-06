# Copyright 2019 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::CacheService::Controller::Influxdb;
use Mojo::Base 'Mojolicious::Controller';

sub minion {
    my $self = shift;

    my $stats = $self->app->minion->stats;
    my $jobs  = {
        active   => $stats->{active_jobs},
        delayed  => $stats->{delayed_jobs},
        failed   => $stats->{failed_jobs},
        inactive => $stats->{inactive_jobs}};
    my $workers = {active => $stats->{active_workers}, inactive => $stats->{inactive_workers}};

    my $url  = $self->req->url->base->to_string;
    my $text = '';
    $text .= _output_measure($url, 'openqa_minion_jobs',    $jobs);
    $text .= _output_measure($url, 'openqa_minion_workers', $workers);

    $self->render(text => $text);
}

sub _output_measure {
    my ($url, $key, $states) = @_;
    my $line = "$key,url=$url ";
    $line .= join(',', map { "$_=$states->{$_}i" } sort keys %$states);
    return $line . "\n";
}

1;
