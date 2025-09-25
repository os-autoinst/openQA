# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings qw(:report_warnings);
use Mojo::Base -strict;
use Test::Output qw(stdout_like);
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::CLI;
use OpenQA::CLI::token;
use OpenQA::Test::TimeLimit '10';


stdout_like { OpenQA::CLI->new->run('help', 'token') } qr/Usage: openqa-cli token/, 'help';
my $host = 'my_host';
my $key = '1234567890ABCDEF';
my $secret = '1234567890ABCDEF';
my $token = 'oqwt-bXlfaG9zdAASNFZ4kKvN7wASNFZ4kKvN7w';
my $cli = OpenQA::CLI::token->new;
stdout_like { $cli->run('encode', join('@', $host, $key, $secret)) } qr/^$token$/, 'encodes expected token';


done_testing;
