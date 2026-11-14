#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::MockModule;
use Test::Warnings ':report_warnings';
use OpenQA::CLI;
use OpenQA::Command;
use OpenQA::Test::TimeLimit '4';

my $seen;
my $command_mock = Test::MockModule->new('OpenQA::Command');
$command_mock->redefine(
    client => sub ($self, @) { $seen = {apikey => $self->apikey, ssh_key => $self->ssh_key}; die "stop\n" });

subtest 'ssh key is taken from the command line after the subcommand' => sub {
    $seen = undef;
    my $ran = eval { OpenQA::CLI->new->run(qw(api --ssh-key /tmp/id jobs)); 1 };
    ok !$ran && $@ =~ /^stop/, 'command runs up to the client creation';
    is $seen->{ssh_key}, '/tmp/id', '--ssh-key is passed to the command client';
    is $seen->{apikey}, undef, 'no API key is set when only an SSH key is given';
};

done_testing();
