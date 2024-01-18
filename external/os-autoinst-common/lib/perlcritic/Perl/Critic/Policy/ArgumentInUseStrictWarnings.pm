# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::ArgumentInUseStrictWarnings;

use strict;
use warnings;
use experimental 'signatures';
use base 'Perl::Critic::Policy';

use Perl::Critic::Utils qw( :severities :classification :ppi );

our $VERSION = '0.0.1';

sub default_severity { return $SEVERITY_HIGH }
sub default_themes { return qw(openqa) }
sub applies_to { return qw(PPI::Statement::Include) }

my $desc = q{use strict/warnings with arguments};
my $expl = q{Remove argument from: %s.};

# check that use use strict and warnings don't have arguments.
sub violates ($self, $elem, $document) {
    # skip if it's not a use
    return unless $elem->type() eq 'use';
    # skip if it's not a pragma
    return unless my $pragma = $elem->pragma();
    # skip if it's not warnings or strict
    return unless ($pragma eq 'warnings' || $pragma eq 'strict');

    my @args = $elem->arguments();
    # skip if it doesn't have arguments
    return if scalar(@args) == 0;

    # allow promoting warnings to FATAL
    return if scalar(grep { $_->content eq 'FATAL' } @args);

    # Report the problem.
    return $self->violation($desc, sprintf($expl, $elem), $elem);
}

1;
