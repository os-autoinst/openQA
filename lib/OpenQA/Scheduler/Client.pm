# Copyright (C) 2014-2019 SUSE LLC
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

package OpenQA::Scheduler::Client;
use Mojo::Base -base;

use OpenQA::Client;
use OpenQA::Scheduler;

has client => sub { OpenQA::Client->new(api => 'localhost') };
has port   => 9529;

sub wakeup {
    my ($self, $worker_id) = @_;
    return if $self->{wakeup};
    $self->{wakeup}++;
    $self->client->max_connections(0)->request_timeout(5)->get_p($self->_api('wakeup'))
      ->finally(sub { delete $self->{wakeup} })->wait;
}

sub singleton { state $client ||= __PACKAGE__->new }

sub _api {
    my ($self, $method) = @_;
    my $port = $self->port;
    return "http://127.0.0.1:$port/api/$method";
}

1;
