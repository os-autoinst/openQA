# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package Perl::Critic::Policy::OpenQA::HashKeyQuotes;

use strict;
use warnings;
use experimental 'signatures';
use base 'Perl::Critic::Policy';

use Perl::Critic::Utils qw( :severities :classification :ppi );

our $VERSION = '0.0.1';

sub default_severity { return $SEVERITY_HIGH }
sub default_themes { return qw(openqa) }
# we only want the check quoted expressions
sub applies_to { return qw(PPI::Token::Quote::Single PPI::Token::Quote::Double) }

# check that hashes are not overly using quotes
# (os-autoinst coding style)
sub violates ($self, $elem, $document) {
    # skip anything that's not a hash key
    return () unless is_hash_key($elem);
    # skip if it has a sibling, e.g. $h{'foo' . 'bar'}
    return () if $elem->snext_sibling or $elem->sprevious_sibling;

    # only some PPI::Token::Quote::* classes implement literal
    my $k = $elem->can('literal') ? $elem->literal : $elem->string;

    # skip anything that has a special symbol in the content
    return () unless $k =~ m/^\w+$/;

    # report violation
    my $desc = q{Hash key with quotes};
    my $expl = qq{Avoid useless quotes for key "$k"};
    return $self->violation($desc, $expl, $elem);
}

1;
