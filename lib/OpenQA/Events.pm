# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Events;
use Mojo::Base 'Mojo::EventEmitter';

sub singleton { state $events = shift->SUPER::new }

# emits an event allowing to pass the usual arguments via named parameter
# note: Supposed to be used from non-controller context. Use the equally named helper
#       to emit events from a controller.
sub emit_event {
    my ($self, $type, %args) = @_;
    die 'missing event type' unless $type;

    my $data = $args{data};
    my $user_id = $args{user_id};
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
