package WebQA::Helpers;

use strict;
use warnings;
use awstandard;
# TODO: Move all needed subs form awstandard to here.

use base 'Mojolicious::Plugin';

sub register {

    my ($self, $app) = @_;

    $app->helper(AWisodatetime2 => sub { shift; return AWisodatetime2(shift); });

    $app->helper(syntax_highlight => sub {
        my $c=shift;
        my $script=shift;
        $script=~s{^sub is_applicable}{# this function decides if the test shall run\n$&}m;
        $script=~s{^sub run}{# this part contains the steps to run this test\n$&}m;
        $script=~s{^sub checklist}{# this part contains known hash values of good or bad results\n$&}m;
        eval "require Perl::Tidy;" or return "<pre>$script</pre>";
        push(@ARGV,"-html", "-css=/dev/null");
        my @out;
        Perl::Tidy::perltidy(
            source => \$script,
            destination => \@out,
        );
        my $out=join("",@out);
        #$out=~s/.*<body>//s;
        $out=~s/.*<!-- contents of filename: perltidy -->//s;
        $out=~s{</body>.*}{}s;
        return $out;
    });
}

1;
