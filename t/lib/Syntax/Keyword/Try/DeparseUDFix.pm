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

1;

sub pp_leave {    # fix https://rt.cpan.org/Ticket/Display.html?id=134812
    my $self = shift;
    my ($op) = @_;

    my $enter = $op->first;
    no strict 'subs';
    no warnings;
    return $self->$orig_pp_leave(@_) if $enter->type != OP_ENTER;

    my $meth = ref $enter->sibling eq "B::COP" ? $orig_pp_leave : $patched_pp_leave;
    return $self->$meth(@_);
}
