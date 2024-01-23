# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::SpaceAfterSubroutineName;

use strict;
use warnings;
use version 0.77;
use experimental 'signatures';

use base 'Perl::Critic::Policy::Subroutines::ProhibitSubroutinePrototypes';

use Perl::Critic::Utils qw{ :severities };

our $VERSION = '0.0.1';

my $DESC = q{Inconsistent sub declaration};
my $EXPL = q{Sub '%s' must have only one space surrounding name, parenthesis and/or block body.};

sub default_themes { qw(openqa) }
sub default_severity { $SEVERITY_HIGHEST }
sub supported_parameters { () }
sub applies_to { 'PPI::Statement::Sub' }

# check that use strict/warnings is not present when equivalent modules are.
sub violates ($self, $elem, $doc) {
    # Grep the first 7 tokens:
    # Case 1: bare sub
    #   0. literal "sub"
    #   1. :space: # must be 1
    #   2. sub_name
    #   3. :space: # must be 1
    #   4. block/structure
    # Case 2: sub with prototype/signature
    #   0. literal "sub"
    #   1. :space: # must be 1
    #   2. sub_name
    #   3. :space: # must be 1
    #   4. prototype
    #   5. :space: # must be 1
    #   6. block/structure

    my @tokens = ($elem->tokens())[0 .. 6];
    return $self->violation($DESC, sprintf($EXPL, $elem->name), $elem) unless _is_surrounded_by_one_space($tokens[2]);

    return () if $tokens[4]->isa('PPI::Token::Structure');

    return $self->violation($DESC, sprintf($EXPL, $elem->name), $elem) unless _is_surrounded_by_one_space($tokens[4]);

    return ();
}

sub _is_only_one_space ($token) {
    return $token->isa('PPI::Token::Whitespace') && $token->content eq ' ';
}

sub _is_surrounded_by_one_space ($token) {
    return _is_only_one_space($token->previous_sibling) && _is_only_one_space($token->next_sibling);
}

1;
