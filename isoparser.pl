#!/usr/bin/perl

use warnings;
use strict;
use Data::Dumper;

sub parse_iso {
    my $iso = shift;

    my $distri = '(openSUSE|SLES)';
    my $version = '(\d+.\d|\d+-SP\d|Factory)';
    my $flavor = '(Addon-(?:Lang|NonOss)|(?:Promo-)?DVD|NET|(?:GNOME|KDE)-Live|Rescue-CD|MINI-ISO)';
    my $arch = '(i[356]86|x86_64|BiArch-i586-x86_64|ia64|ppc64|s390x)';
    my $build = '(Build(?:\d+))';

    my @parts = $iso =~ /^$distri(?:-$version)?-$flavor-$arch(?:-$build)?.*\.iso$/i;

    if( @parts ) {
        my %params;
        @params{qw(distri version flavor arch build)} = @parts;
        $params{version} ||= 'Factory';
        
        if (wantarray()) {
            return %params;
        }
        else {
            return \%params;
        }
    }
    else {
        return undef;
    }
}

while ( chomp( my $line = <> ) ) {
    print "$line:";
    
    my $params = parse_iso($line);

    if ( $params ) {
        print "\n" . Dumper($params);
    }
    else {
        print " no match\n";
    };
}
