BEGIN { unshift @INC, 'lib', 'lib/OpenQA/modules'; }

# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

use Mojo::Base -strict;
use db_helpers qw/rndstr rndhex rndstrU rndhexU/;

use Test::More;

my $r;
my $r2;

$r = rndstr;
$r2 = rndstr;
is(length($r), 16, "length 16");
like($r, qr/^\w+$/a, "rndstr only consists of word characters");
is(length($r), length($r2), "same length");
isnt($r, $r2, "rndstr produces different results");

$r = rndstr 32;
$r2 = rndstr 32;
is(length($r), 32, "length 32");
like($r, qr/^\w+$/a, "rndstr only consists of word characters");
is(length($r), length($r2), "same length");
isnt($r, $r2, "rndstr produces different results");

$r = rndhex;
$r2 = rndhex;
is(length($r), 16, "length 16");
like($r, qr/^[0-9A-F]+$/a, "rndhex only consists of hex characters");
is(length($r), length($r2), "same length");
isnt($r, $r2, "rndhex produces different results");

$r = rndhex 32;
$r2 = rndhex 32;
is(length($r), 32, "length 32");
like($r, qr/^[0-9A-F]+$/a, "rndhex only consists of hex characters");
is(length($r), length($r2), "same length");
isnt($r, $r2, "rndhex produces different results");

$r = rndstrU 256;
$r2 = rndstrU 256;
is(length($r), 256, "length 256");
like($r, qr/^\w+$/a, "rndstrU only consists of word characters");
is(length($r), length($r2), "same length");
isnt($r, $r2, "rndstrU produces different results");

$r = rndhexU 256;
$r2 = rndhexU 256;
is(length($r), 256, "length 256");
like($r, qr/^[0-9A-F]+$/a, "rndhexU only consists of hex characters");
is(length($r), length($r2), "same length");
isnt($r, $r2, "rndhexU produces different results");

done_testing();
