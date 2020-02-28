#!/usr/bin/env perl
use strict;
use warnings;

if ($ARGV[0] ne '--version') {
    print("This script is only meant to test the isotovideo version check.\n");
    exit(-1);
}

print("Current version is 4.5.1559738889.52a75c17 [interface v15]\n");
