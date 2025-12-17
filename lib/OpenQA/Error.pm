# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Error;

use Mojo::Base -base, -signatures;

has signal => 0;
has 'msg';

# Automatically render error message in string context
# Perl::Critic::Policy::Community::OverloadOptions
use overload '""' => \&to_string, bool => sub { 1 }, fallback => 1;

sub to_string ($self, @) { (ref $self) . ': ' . $self->msg }

sub shutting_down ($self) {
    grep { ($self->signal // 0) eq $_ } qw(INT TERM);
}

1;
