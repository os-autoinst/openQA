package ACOVER;
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

use Syntax::Keyword::Try::DeparseUDFix;    # enable try/catch coverage

#use Devel::Cover qw' -ignore ^t/ -coverage statement branch condition path subroutine ';

# this is for the sketched pushmark/leaveasync cover fixes below
# use Module::Runtime 'use_module';
# our $IS_ASYNC = 0;

# this silences warnings about some dynamically generated code
no warnings 'uninitialized';
$Devel::Cover::DB::Ignore_filenames = qr@
	$Devel::Cover::DB::Ignore_filenames

	| # SpecIO
	(?: ^Specio::\S+-\> )
	| # Moose
	(?: ^reader\ Moose::Meta::Class:: )
	| # Moose
	(?: ^inline\ delegation\ in )
	| # SSLeay
	(?: blib/lib/Net/SSLeay.pm )
    |
	(?: exportable\ function )
    |
	(?: compiled\ check )
    |
	(?: compiled\ assertion )
    |
	(?: compiled\ coercion )
    |
	(?: generated\ by\ Specio:: )
    |
	(?: inlined\ sub\ for )
@x;

1;

sub B::Deparse::pp_await {    # fix await parsing
    my ($self, $op, $cx) = @_;
    return $self->maybe_parens_unop("await", $op->first, $cx);
}

# dumb way to handle these, simply silences them instead of deparsing them
# optimally the code below would be implemented
sub B::Deparse::pp_leaveasync { "XXX;" }
sub B::Deparse::pp_pushmark { "XXX;" }

=head1 sketched pushmark/leaveasync cover fixes

sub mock_method {
	my ( $module, $method, $cb ) = @_;
	my $old = use_module($module)->can($method);

	my $wrapped_cb = sub { $cb->( $old, @_ ) };
	no warnings 'redefine';
	no warnings 'prototype';
	no strict 'refs';
	*{ $module . "::" . $method } = $wrapped_cb;
	return;
}

mock_method "B::Deparse" => next_todo => sub {
	print "meep\n";
	my ( $old,  $self ) = @_;
	my ( undef, $cv )   = @{ $self->{subs_todo}[0] };
	local $IS_ASYNC = { meep => 1, do_a_thing => 1 }->{ $self->gv_name( $cv->GV ) } ? 1 : 0;
	return $old->($self);
};

mock_method "B::Deparse" => keyword => sub {
	my ( $old, $self, $thing ) = @_;
	my $real = $old->( $self, $thing );
	return ( $IS_ASYNC and $thing eq "sub" ) ? "async $real" : $real;
};

sub B::Deparse::pp_pushmark {
	$IS_ASYNC ? "" : do { warn "unexpected pushmark"; "XXX" }
}

sub B::Deparse::pp_leaveasync {
	$IS_ASYNC ? "" : do { warn "unexpected leaveasync"; "XXX" }
}

=cut
