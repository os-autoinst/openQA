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
# with this program; if not, see <http://www.gnu.org/licenses/>.

BEGIN {
    unshift @INC, 'lib';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use Test::Warnings;
use OpenQA::Test::Case;

use File::Temp qw(tempfile);

my ($fh, $filename) = tempfile();

$ENV{MOJO_LOG_LEVEL}   = 'debug';
$ENV{OPENQA_SQL_DEBUG} = 'true';
$ENV{OPENQA_LOGFILE}   = $filename;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# now get some DB action done
$t->get_ok('/tests')->status_is(200);

open(FILE, $filename);
my @lines = <FILE>;
close(FILE);

like(join('', @lines), qr/.*debug\] \[DBIx debug\] Took .* seconds executed: SELECT.*/, "seconds in log file");

done_testing();
