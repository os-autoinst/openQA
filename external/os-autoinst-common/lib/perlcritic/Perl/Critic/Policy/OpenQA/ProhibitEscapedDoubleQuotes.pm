# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::OpenQA::ProhibitEscapedDoubleQuotes;

use strict;
use warnings;
use experimental 'signatures';
use base 'Perl::Critic::Policy';

use Perl::Critic::Utils qw( :severities );

our $VERSION = '0.0.1';

my $DESC = q{Nested escaped double quotes in double-quoted string};
my $EXPL = q{Use qq{...} or other delimiters to avoid backslash-escaping double quotes inside strings};

sub default_severity { $SEVERITY_MEDIUM }
sub default_themes { qw(openqa) }
sub applies_to { qw(PPI::Token::Quote::Double) }

sub violates ($self, $elem, $doc) {
    return $elem->string =~ tr/\"// ? $self->violation($DESC, $EXPL, $elem) : ();
}

1;
