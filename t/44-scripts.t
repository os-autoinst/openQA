#!/usr/bin/env perl
# Copyright (C) 2020 SUSE LLC
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

use Test::Most;

use FindBin '$Bin';
use lib "$FindBin::Bin/lib";
use OpenQA::Test::TimeLimit '20';
my %allowed_types = (
    'text/x-perl'   => 1,
    'text/x-python' => 1,
);

# Could also use MIME::Types, would be new dependency
chomp(my @types = qx{cd $Bin/../script; for i in *; do echo \$i; file --mime-type --brief \$i; done});

my %types = @types;
for my $key (keys %types) {
    delete $types{$key} unless $allowed_types{$types{$key}};
}

for my $script (sort keys %types) {
    my $out = qx{$Bin/../script/$script --help 2>&1};
    my $rc  = $?;
    is($rc, 0, "Calling '$script --help' returns exit code 0")
      or diag "Output: $out";
}

done_testing;
