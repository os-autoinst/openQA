# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::RedundantStrictWarning;

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

    # Bail out if there's only one. TestingAndDebugging::RequireUseStrict will report
    # that there's no use strict/warnings.
    return if scalar @{$use_stmts} == 1;

    # If the 'use strict' or 'use warnings' statement is present as well as a
    # module already providing that behavior, -> it violates.
    return map { $self->_make_violation($_) } grep { !$_->pragma() } @{$use_stmts};
}

sub _make_violation ($self, $statement) {
    return $self->violation($policy_title, sprintf($policy_explanation, $statement), $statement);
}

1;

