#!/usr/bin/env perl
# Copyright 2017-2021 SUSE Linux LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Utils;
require OpenQA::Test::Database;
use OpenQA::Test::Utils qw(run_gru_job);
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;
use Test::MockModule;
use Test::Warnings ':report_warnings';

my $schema = OpenQA::Test::Database->new->create;
my $t = Test::Mojo->new('OpenQA::WebAPI');
my $bugs = $schema->resultset('Bugs');
my $app = $t->app;
my $c = $app->build_controller;

my $bug = $bugs->get_bug('poo#200');
ok !defined $bug, 'bug not refreshed';

$bugs->find(1)->update({refreshed => 1, title => 'foo bar < " & ß'});
$bug = $bugs->get_bug('poo#200');
ok $bug->refreshed, 'bug refreshed';
ok $bug->bugid, 'bugid matched';
is $c->bugtitle_for('poo#200', $bug), qq{Bug referenced: poo#200\nfoo bar < " & ß}, 'bug title not already escaped';

subtest 'Unreferenced bugs cleanup job works' => sub {
    # create some more bugs
    $bugs->get_bug('poo#201');
    $bugs->get_bug('poo#202');
    $schema->resultset('Jobs')->create(
        {
            id => 421,
            TEST => 'textmode',
        });
    $schema->resultset('Comments')->create(
        {
            job_id => 421,
            user_id => 1,
            text => 'poo#202',
        });
    ok $bugs->count > 0, 'Bugs available for cleanup';

    run_gru_job($app, 'limit_bugs');
    is $bugs->count, 1, 'Bugs cleaned up';
    ok $bugs->find({bugid => 'poo#202'}), 'Bug poo#202 not cleaned up due to reference from comment';
};

subtest 'implicit insert conflicts with a bug inserted meanwhile' => sub {
    my $mock = Test::MockModule->new('OpenQA::Schema::ResultSet::Bugs');
    my $orig_find = $mock->original('find');
    my $first_find = 1;
    $mock->redefine(
        find => sub {
            my ($self, @args) = @_;
            if ($first_find && ref $args[0] eq 'HASH' && ($args[0]->{bugid} // '') eq 'poo#300') {
                $first_find = 0;
                $self->create({bugid => 'poo#300', refreshed => 1, existing => 1, title => 'concurrent bug'});
                return undef;
            }
            return $orig_find->($self, @args);
        });

    my $res = $bugs->get_bug('poo#300');
    ok $res, 'bug returned despite concurrent insert race';
    is $res->bugid, 'poo#300', 'correct bugid';
    is $res->title, 'concurrent bug', 'correct title from concurrent insert';
};

done_testing();
