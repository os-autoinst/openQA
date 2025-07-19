package CoverageWorkaround;
use strict;
use warnings;

=head1 DESCRIPTION

A wrapper around Devel::Cover, configuring some things to enable covering some
things default D::C misses, and to make it less noisy. Run this to generate a
coverage report on the tests:

    cover -delete && HARNESS_PERL_SWITCHES='-Ilib -MACover' prove -r t && cover

=cut

# prevent these two from interfering with coverage
BEGIN { $INC{$_}++ for qw( DB/Skip.pm UDAG/VendorBox/Log/Auto.pm ) }

#use Devel::Cover qw' -ignore ^t/ -coverage statement branch condition path subroutine ';

# this is for the sketched pushmark/leaveasync cover fixes below
# use Module::Runtime 'use_module';
# our $IS_ASYNC = 0;

# this silences warnings about some dynamically generated code
#no warnings 'uninitialized';
#$Devel::Cover::DB::Ignore_filenames = qr@
#	$Devel::Cover::DB::Ignore_filenames
#
#	| # SpecIO
#	(?: ^Specio::\S+-\> )
#	| # Moose
#	(?: ^reader\ Moose::Meta::Class:: )
#	| # Moose
#	(?: ^inline\ delegation\ in )
#	| # SSLeay
#	(?: blib/lib/Net/SSLeay.pm )
#    |
#	(?: exportable\ function )
#    |
#	(?: compiled\ check )
#    |
#	(?: compiled\ assertion )
#    |
#	(?: compiled\ coercion )
#    |
#	(?: generated\ by\ Specio:: )
#    |
#	(?: inlined\ sub\ for )
#@x;

sub B::Deparse::pp_await {    # fix await parsing
    my ($self, $op, $cx) = @_;
    return $self->maybe_parens_unop('await', $op->first, $cx);
}

# dumb way to handle these, simply silences them instead of deparsing them
# optimally the code below would be implemented
sub B::Deparse::pp_leaveasync { 'XXX;' }
sub B::Deparse::pp_pushmark { 'XXX;' }

package Syntax::Keyword::Try::DeparseUDFix;
use strict;
use warnings;

use B::Deparse;    # keep original pp_leave sub for 134812 fix below
my $orig_pp_leave;
BEGIN { $orig_pp_leave = \&B::Deparse::pp_leave; }

use Syntax::Keyword::Try::Deparse;    # enable try/catch deparsing for coverage

my $patched_pp_leave;    # apply 134812 fix below
{
    $patched_pp_leave = \&B::Deparse::pp_leave;
    no warnings 'redefine';
    *B::Deparse::pp_leave = \&pp_leave;
}

sub pp_leave {    # fix https://rt.cpan.org/Ticket/Display.html?id=134812
    my $self = shift;
    my ($op) = @_;

    my $enter = $op->first;
    no strict 'subs';
    no warnings;
    return $self->$orig_pp_leave(@_) if $enter->type != OP_ENTER;

    my $meth = ref $enter->sibling eq 'B::COP' ? $orig_pp_leave : $patched_pp_leave;
    return $self->$meth(@_);
}

1;
