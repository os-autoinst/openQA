#!/usr/bin/env perl -w
# Copyright (C) 2018 SUSE LLC
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

use strict;
use warnings;
use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use Test::More;
use OpenQA::Client;
use OpenQA::File 'path';

subtest split => sub {

    is path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->size, 6991, 'size matches';

    is OpenQA::File::_chunk_size(20, 10), 2, 'calculated chunk match';
    is OpenQA::File::_chunk_size(21, 10), 3;
    is OpenQA::File::_chunk_size(29, 10), 3;
    is OpenQA::File::_chunk_size(30, 10), 3;
    is OpenQA::File::_chunk_size(31, 10), 4;

    my $pieces = path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->split(2000);

    is $pieces->compose(), path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->slurp, 'Content match'
      or die diag explain $pieces;
};

done_testing();
1;
