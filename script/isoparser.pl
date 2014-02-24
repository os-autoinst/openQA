#!/usr/bin/perl

use warnings;
use strict;
use Data::Dumper;
use FindBin;
use lib $FindBin::Bin.'/../www/cgi-bin/modules';
use openqa qw(parse_iso);

while ( my $line = <> ) {
    chomp $line;
    $line =~ s|^.*/||;
    print "$line:";
    
    my $params = parse_iso($line);

    if ( $params ) {
        print "\n" . Dumper($params);
    }
    else {
        print " no match\n";
    };
}
