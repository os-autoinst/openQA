# Copyright 2018-2019 SUSE LLC
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

package OpenQA::Events;
use Mojo::Base 'Mojo::EventEmitter';

sub singleton { state $events = shift->SUPER::new }

# emits an event allowing to pass the usual arguments via named parameter
# note: Supposed to be used from non-controller context. Use the equally named helper
#       to emit events from a controller.
sub emit_event {
    my ($self, $type, %args) = @_;
    die 'missing event type' unless $type;

    my $data       = $args{data};
    my $user_id    = $args{user_id};
    my $connection = $args{connection};

    return $self->emit($type, [$user_id, $connection, $type, $data]);
}

1;

=encoding utf8

=head1 NAME

OpenQA::Events - A global event emitter for openQA

=head1 SYNOPSIS

  use OpenQA::Events;

  # Emit events
  OpenQA::Events->singleton->emit(some_event => ['some', 'argument']);

  # Do something whenever an event occurs
  OpenQA::Events->singleton->on(some_event => sub {
    my ($events, @args) = @_;
    ...
  });

  # Do something only once if an event occurs
  OpenQA::Events->singleton->once(some_event => sub {
    my ($events, @args) = @_;
    ...
  });

=head1 DESCRIPTION

L<OpenQA::Events> is a global event emitter for L<OpenQA> that is usually used
as a singleton object. It is based on L<Mojo::EventEmitter> and can be used from
anywhere inside the same process.

=cut
