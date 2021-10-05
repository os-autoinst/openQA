# Copyright 2014-2021 SUSE LLC
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
use Mojo::Base -base, -signatures;

use OpenQA::Client;
use OpenQA::Log 'log_warning';
use OpenQA::Utils 'service_port';

has host   => sub { $ENV{OPENQA_SCHEDULER_HOST} };
has client => sub { OpenQA::Client->new(api => shift->host // 'localhost') };
has port   => sub { service_port('scheduler') };

my $IS_SCHEDULER_ITSELF;
sub mark_current_process_as_scheduler { $IS_SCHEDULER_ITSELF = 1; }
sub is_current_process_the_scheduler  { return $IS_SCHEDULER_ITSELF; }

sub new {
    my $class = shift;
    die 'creating an OpenQA::Scheduler::Client from the scheduler itself is forbidden'
      if is_current_process_the_scheduler;
    $class->SUPER::new(@_);
}

sub wakeup {
    my ($self, $worker_id) = @_;
    return if $self->{wakeup};
    $self->{wakeup}++;
    $self->client->max_connections(0)->request_timeout(5)->get_p($self->_api('wakeup'))
      ->catch(sub { log_warning("Unable to wakeup scheduler: $_[0]") })->finally(sub { delete $self->{wakeup} })->wait;
}

sub singleton { state $client ||= __PACKAGE__->new }

sub _api ($self, $method) {
    my ($host, $port) = ($self->host // '127.0.0.1', $self->port);
    return "http://$host:$port/api/$method";
}

1;
