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

package OpenQA::Worker::Isotovideo::Client;
use Mojo::Base -base;

use Mojo::UserAgent;
use OpenQA::Log qw(log_info log_debug);

has job => undef, weak => 1;
has ua => sub { Mojo::UserAgent->new };

sub stop_gracefully {
    my ($self, $reason, $callback) = @_;

    return Mojo::IOLoop->next_tick($callback) unless my $url = $self->url;
    $url .= '/broadcast';

    log_info('Trying to stop job gracefully by announcing it to command server via ' . $url);
    my $ua          = $self->ua;
    my $old_timeout = $ua->request_timeout;
    $ua->request_timeout(10);
    $ua->post(
        $url => json => {stopping_test_execution => $reason} => sub {
            my ($ua, $tx) = @_;

            my $res = $tx->res;
            if (!$res->is_success) {
                log_info('Unable to stop the command server gracefully: ');
                log_info($res->code ? $res->to_string : 'Command server likely not reachable at all');
            }
            $callback->();
        });
    $ua->request_timeout($old_timeout);
}

sub url {
    my $self = shift;
    return undef unless my $info = $self->job->info;
    return $info->{URL};
}

1;
