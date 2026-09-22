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

sub default_severity { return $SEVERITY_MEDIUM }
sub default_themes { return qw(openqa) }
sub applies_to { return qw(PPI::Token::Quote::Double) }

sub violates ($self, $elem, $doc) {
    my $content = $elem->content;

    # Strip the enclosing double quotes of PPI::Token::Quote::Double
    my $inner = $content;
    if ($inner =~ s/^"// && $inner =~ s/"$//) {
        # Match a double quote preceded by an odd number of backslashes
        if ($inner =~ /(?<!\\)(?:\\\\)*\\"/ ) {
            return $self->violation($DESC, $EXPL, $elem);
        }
    }

    return ();
}

1;
