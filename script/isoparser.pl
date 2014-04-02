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
# vim: set sw=4 sts=4 et:
