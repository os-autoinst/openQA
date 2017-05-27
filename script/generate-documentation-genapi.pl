#!/usr/bin/env perl

# Copyright (C) 2016-2017 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

# Internal script for generate-documentation to create asciidoc from POD
# in os-autoinst

use strict;
use warnings;

my $adoc;

eval 'use Pod::AsciiDoctor';
eval {
    # make sure compile-all does not barf here
    $adoc = Pod::AsciiDoctor->new();
};

if ($@ || !$adoc) {
    print "Make sure to install Pod::AsciiDoctor if you meant to run this script\n";
    die $@;
}

my $data_dir = "./src/";
opendir(DIR, $data_dir) or die("Cannot read directories: $data_dir");
my @files = grep { /\.pm$/ } readdir DIR;

foreach my $current_file (@files) {

    open(my $ifh, '<', $data_dir . $current_file) or die("Cannot open $current_file");
    $current_file =~ s/^(.*)\.pm$/$1.asciidoc/;
    open(my $ofh, ">", $current_file) or die("Cannot open $current_file");

    print "Transforming $current_file\n";
    $adoc->append("include::header.asciidoc[]");
    $adoc->append("\n");
    $adoc->parse_from_filehandle($ifh);

    print $ofh $adoc->adoc();
    close($ofh);
    close($ifh);

}
