# Copyright 2014-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';

use File::Temp qw(tempfile);

my ($fh, $filename) = tempfile();

$ENV{MOJO_LOG_LEVEL} = 'debug';
$ENV{OPENQA_SQL_DEBUG} = 'true';
$ENV{OPENQA_LOGFILE} = $filename;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA::WebAPI');

# now get some DB action done
$t->get_ok('/tests')->status_is(200);

open(FILE, $filename);
my @lines = <FILE>;
close(FILE);

like(join('', @lines), qr/.*debug\] \[pid:.*\] \[DBIC\] Took .* seconds: SELECT.*/, "seconds in log file");

done_testing();
