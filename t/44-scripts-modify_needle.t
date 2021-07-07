#!/usr/bin/env perl
# Copyright (C) 2021 SUSE LLC
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
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use Mojo::File qw(path tempdir);
use Mojo::JSON qw(decode_json);

my $tempdir = tempdir;
path("$Bin/data/default-needle.json")->copy_to($tempdir);
qx{$Bin/../script/modify_needle --add-tags FOO=BAR $tempdir/default-needle.json};
is decode_json(path("$tempdir/default-needle.json")->slurp)->{tags}->[1], 'FOO=BAR', 'tag added to needle file';
done_testing;
