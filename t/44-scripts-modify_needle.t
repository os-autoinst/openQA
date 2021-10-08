#!/usr/bin/env perl
# Copyright 2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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
