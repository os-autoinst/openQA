# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Error::Cmd;

use Mojo::Base -base, -signatures;

has [qw(status return_code stdout stderr signal msg)];

# Perl::Critic::Policy::Community::OverloadOptions
# Automatically render error message in string context
use overload '""' => \&to_string, bool => sub { 1 }, fallback => 1;

sub to_string ($self, @) { (ref $self) . ': ' . $self->msg }

1;
