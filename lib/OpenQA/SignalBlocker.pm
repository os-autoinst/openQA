# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::SignalBlocker;
use Mojo::Base -base, -signatures;
use Scalar::Util qw(weaken);

my @SIGNALS = qw(TERM INT);

# delays execution of signal handlers while an instance exists
sub new ($class, @attributes) {
    my $self = $class->SUPER::new(@attributes);
    $self->{_fired_signals} = [];
    $self->{_blocked_handlers} = {map { ($_ => $SIG{$_}) } @SIGNALS};

    # assign closure to global signal handlers using a weak reference to $self so DESTROY will still run
    my $self_weak = $self;
    weaken $self_weak;
    my $handler = sub ($signal) { push @{$self_weak->{_fired_signals}}, $signal };
    $SIG{$_} = $handler for @SIGNALS;
    return $self;
}

sub DESTROY ($self) {
    my $blocked_handlers = $self->{_blocked_handlers};
    $SIG{$_} = $blocked_handlers->{$_} for @SIGNALS;

    # execute signals that have fired while the blocker was present
    for my $signal (@{$self->{_fired_signals}}) {
        next unless my $handler = $blocked_handlers->{$signal};
        $handler->($signal) unless $handler eq 'IGNORE';
    }
}

1;
