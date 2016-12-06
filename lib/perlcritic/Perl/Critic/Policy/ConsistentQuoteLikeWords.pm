package Perl::Critic::Policy::ConsistentQuoteLikeWords;

use strict;
use warnings;

use Perl::Critic::Utils qw( :severities :classification :ppi );
use base 'Perl::Critic::Policy';

our $VERSION = '0.0.1';

sub default_severity { return $SEVERITY_HIGH }
sub default_themes   { return qw(openqa) }
sub applies_to       { return qw(PPI::Token::QuoteLike::Words) }

# check that qw is used as function and only for multiple values
# (os-autoinst coding style)

sub violates {
    my ($self, $elem) = @_;

    my $desc = q{qw should be used as function};
    my $expl = q{use qw(A B)};

    if ($elem =~ m/^\Qqw(\E/) {
        return unless $elem->parent->isa('PPI::Statement::Include');
        # ok if there is whitespace too
        return unless $elem =~ /^qw\(\s*\S+\s*\)$/;
        return unless $elem->parent->isa('PPI::Statement::Include');
        $expl = q{use MODULE 'func' for single imports};
    }
    return $self->violation($desc, $expl, $elem);
}

1;
