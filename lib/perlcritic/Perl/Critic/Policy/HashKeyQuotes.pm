package Perl::Critic::Policy::HashKeyQuotes;

use strict;
use warnings;

use base 'Perl::Critic::Policy';

use Perl::Critic::Utils qw( :severities :classification :ppi );

our $VERSION = '0.0.1';

sub default_severity { return $SEVERITY_HIGH }
sub default_themes { return qw(openqa) }
sub applies_to { return qw(PPI::Token::Quote::Single PPI::Token::Quote::Double) }

# check that hashes are not overly using quotes
# (os-autoinst coding style)

sub violates {
    my ($self, $elem) = @_;

    #we only want the check hash keys
    return if !is_hash_key($elem);

    my $c = $elem->content;
    # special characters
    return if $c =~ m/[- \/<>.=_:\\\$]/;

    my $desc = q{Hash key with quotes};
    my $expl = q{Avoid useless quotes};
    return $self->violation($desc, $expl, $elem);
}

1;
