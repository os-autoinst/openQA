#!/usr/bin/env perl

use warnings;
use strict;
use Data::Dumper;
use FindBin;
BEGIN { unshift @INC, $FindBin::Bin.'/../lib', $FindBin::Bin.'/../lib/OpenQA/modules'; }
use openqa::distri::opensuse ();

while ( my $line = <> ) {
    chomp $line;
    $line =~ s|^.*/||;
    print "$line:";
    
    my $params = openqa::distri::opensuse::parse_iso($line);

    if ( $params ) {
        print "\n" . Dumper($params);
    }
    else {
        print " no match\n";
    };
}
# Local Variables:
# mode: cperl
# cperl-close-paren-offset: -4
# cperl-continued-statement-offset: 4
# cperl-indent-level: 4
# cperl-indent-parens-as-block: t
# cperl-tab-always-indent: t
# indent-tabs-mode: nil
# End:
# vim: set ts=4 sw=4 sts=4 et:
