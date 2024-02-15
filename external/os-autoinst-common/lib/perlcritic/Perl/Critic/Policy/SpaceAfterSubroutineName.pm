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
    # Grep the first 7 tokens: each function will validate the cases.
    my @tokens = ($elem->tokens())[0 .. 6];

    return () if $elem->forward();
    return $self->check_reserved_sub($elem, @tokens) if _is_reserved_sub($elem);
    return $self->check_classic_sub($elem, @tokens) unless defined($elem->prototype);
    return $self->check_complete_sub($elem, @tokens);
}

sub report_violation ($self, $elem) {
    return $self->violation($DESC, sprintf($EXPL, $elem->name), $elem);
}

sub check_reserved_sub ($self, $elem, @tokens) {
    # "Reserved Sub" token desired layout
    # 0. Word - END/BEGIN/etc.
    # 1. Whitespace
    # 2. Structure - the actual code block.
    return () if _is_only_one_space($tokens[1]) && _is_block($tokens[2]);
    return $self->report_violation($elem);
}

sub check_classic_sub ($self, $elem, @tokens) {
    # "Classic Sub" token desired layout
    #   0. Word "sub"
    #   1. Whitespace - must be 1
    #   2. Word - the sub name
    #   3. Whitespace - must be 1
    #   4. Structure - the actual code block

    return () if _is_surrounded_by_one_space($tokens[2]);
    return $self->report_violation($elem);
}

sub check_complete_sub ($self, $elem, @tokens) {
    # "Complete Sub" token desired layout
    #   0. Word "sub"
    #   1. Whitespace - must be 1
    #   2. Word - the sub name
    #   3. Whitespace - must be 1
    #   4. Prototype - sub's prototype/signature
    #   5. Whitespace - must be 1
    #   6. Structure - the actual code block

    return () if _is_surrounded_by_one_space($tokens[2]) && _is_surrounded_by_one_space($tokens[4]);
    return $self->report_violation($elem);
}

sub _is_block ($token) {
    return $token->isa('PPI::Token::Structure');
}

sub _is_only_one_space ($token) {
    return $token->isa('PPI::Token::Whitespace') && $token->content eq ' ';
}

sub _is_surrounded_by_one_space ($token) {
    return _is_only_one_space($token->previous_sibling) && _is_only_one_space($token->next_sibling);
}

sub _is_reserved_sub ($elem) {
    return $elem->isa('PPI::Statement::Scheduled');
}

1;
