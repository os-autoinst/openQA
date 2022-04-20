package OpenQA::Test::PatchDeparse;
use Test::Most;

# Monkeypatch B::Deparse
# https://progress.opensuse.org/issues/40895
# related: https://github.com/pjcj/Devel--Cover/issues/142
# http://perlpunks.de/corelist/mversion?module=B::Deparse


# This might be fixed in newer versions of perl/B::Deparse
# We only see a warning when running with Devel::Cover
if (
    $B::Deparse::VERSION
    and ($B::Deparse::VERSION >= '1.40' and ($B::Deparse::VERSION <= '1.54'))
  )
{

#<<<  do not let perltidy touch this
# This is not our code, and formatting should stay the same for
# better comparison with new versions of B::Deparse
# <---- PATCH
package B::Deparse;
no warnings 'redefine';
no strict 'refs';

*{"B::Deparse::walk_lineseq"} = sub {

    my ($self, $op, $kids, $callback) = @_;
    my @kids = @$kids;
    for (my $i = 0; $i < @kids; $i++) {
	my $expr = "";
	if (is_state $kids[$i]) {
        # Patch for:
        # Use of uninitialized value $expr in concatenation (.) or string at /usr/lib/perl5/5.26.1/B/Deparse.pm line 1794.
	    $expr = $self->deparse($kids[$i++], 0) // ''; # prevent undef $expr
	    if ($i > $#kids) {
		$callback->($expr, $i);
		last;
	    }
	}
	if (is_for_loop($kids[$i])) {
	    $callback->($expr . $self->for_loop($kids[$i], 0),
		$i += $kids[$i]->sibling->name eq "unstack" ? 2 : 1);
	    next;
	}
	my $expr2 = $self->deparse($kids[$i], (@kids != 1)/2) // ''; # prevent undef $expr2
	$expr2 =~ s/^sub :(?!:)/+sub :/; # statement label otherwise
	$expr .= $expr2;
	$callback->($expr, $i);
    }

};
# ----> PATCH
#>>>

}
elsif ($B::Deparse::VERSION) {
    # when we update to a new perl version, this will remind us about checking
    # if the bug is still there
    diag
      "Using B::Deparse v$B::Deparse::VERSION. If you see 'uninitialized' warnings, update patch in t/lib/OpenQA/Test/PatchDeparse.pm";
}

1;


