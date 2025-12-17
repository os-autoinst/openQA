# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Error;

use Mojo::Base -base, -signatures;
use POSIX qw(:signal_h);

has signal => 0;
has [qw(msg)];

# Perl::Critic::Policy::Community::OverloadOptions
use overload '""' => \&to_string, bool => sub { 1 }, fallback => 1;

sub to_string ($self, @) { (ref $self) . ': ' . $self->msg }

sub shutting_down ($self) {
    not $self->status and grep { ($self->signal // 0) == $_ } (SIGINT, SIGTERM);
}

1;
