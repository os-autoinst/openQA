# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::OpenQA::RedundantStrictWarning;

use strict;
use warnings;
use version 0.77;
use experimental 'signatures';

use base 'Perl::Critic::Policy::TestingAndDebugging::RequireUseStrict';
use Perl::Critic::Utils qw{ $EMPTY };
use Perl::Critic::Utils::Constants qw{ :equivalent_modules };

our $VERSION = '0.0.1';
my $policy_title = q{Superfluoux use of strict/warning};
my $policy_explanation = q{%s is equivalent to 'use strict; use warnings;'};

sub default_themes { return qw(openqa) }

sub supported_parameters {
    return (
        {
            name => 'equivalent_modules',
            description =>
              q<The additional modules to treat as equivalent to "strict" or "warnings".>,
            default_string => $EMPTY,
            behavior => 'string list',
            list_always_present_values => ['warnings', 'strict', @STRICT_EQUIVALENT_MODULES],
        },
    );
}

# check that use strict/warnings is not present when equivalent modules are.
sub violates ($self, $, $doc) {
    # Find all equivalents of use strict/warnings.
    my $use_stmts = $doc->find($self->_generate_is_use_strict());

    # Bail if there's none.
    return unless $use_stmts;

    my ($use_strict, $use_warnings, $mojo_strict, $mojo, @other);
    for my $stmt (@$use_stmts) {
        my $module = $stmt->module;
        if ($module eq 'strict') { $use_strict = $stmt }
        elsif ($module eq 'warnings') { $use_warnings = $stmt }
        elsif ($module eq 'Mojo::Base') {
            # "use Mojo::Base 'somebaseclass'" or "use Mojo::Base -signatures" is
            # not a superfluous strict usage. Only "use Mojo::Base -strict".
            $mojo_strict = $stmt if _analyze_mojo_base($stmt);
            $mojo = 1;
        }
        else {
            push @other, $stmt;
        }
    }
    my @violating;
    if (@other) {
        push @violating, grep { $_ } ($use_strict, $use_warnings, $mojo_strict);
    }
    elsif ($mojo) {
        push @violating, grep { $_ } ($use_strict, $use_warnings);
    }
    return map { $self->_make_violation($_) } @violating;
}

sub _analyze_mojo_base ($stmt) {
    my @args;
    for my $token ($stmt->arguments) {
        next if $token->isa('PPI::Token::Operator');
        if ($token->isa('PPI::Token::Quote')) {
            push @args, $token->string;
        }
        elsif ($token->isa('PPI::Token::QuoteLike::Words')) {
            push @args, $token->literal;
        }
        elsif ($token->isa('PPI::Token::Word')) {
            # unquoted word
            push @args, $token->content;
        }
    }
    if (grep { m/^-strict$/ } @args) {
        return $stmt;
    }
    return 0;
}

sub _make_violation ($self, $statement) {
    return $self->violation($policy_title, sprintf($policy_explanation, $statement), $statement);
}

1;

