# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';
use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use OpenQA::CLI;
use OpenQA::Test::TimeLimit '4';

my $cli = OpenQA::CLI->new;
is_deeply $cli->namespaces, ['OpenQA::CLI'], 'right namespaces';

done_testing();
