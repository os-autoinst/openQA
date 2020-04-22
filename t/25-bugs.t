#!/usr/bin/env perl
# Copyright (C) 2017-2020 SUSE Linux LLC
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

use FindBin;
use lib "$FindBin::Bin/lib";
use OpenQA::Utils;
use OpenQA::Test::Database;
use OpenQA::Test::Utils qw(run_gru_job collect_coverage_of_gru_jobs);
use Test::Mojo;
use Test::Warnings;

my $schema = OpenQA::Test::Database->new->create(skip_fixtures => 1);
my $t      = Test::Mojo->new('OpenQA::WebAPI');
my $bugs   = $schema->resultset('Bugs');
my $app    = $t->app;
my $c      = $app->build_controller;

collect_coverage_of_gru_jobs($app);

my $bug = $bugs->get_bug('poo#200');
ok(!defined $bug, 'bug not refreshed');

$bugs->find(1)->update({refreshed => 1, title => 'foo bar < " & ß'});
$bug = $bugs->get_bug('poo#200');
ok($bug->refreshed, 'bug refreshed');
ok($bug->bugid,     'bugid matched');
is($c->bugtitle_for('poo#200', $bug), "Bug referenced: poo#200\nfoo bar < \" & ß", 'bug title not already escaped');

subtest 'Unreferenced bugs cleanup job works' => sub {
    # create some more bugs
    $bugs->get_bug('poo#201');
    $bugs->get_bug('poo#202');
    $schema->resultset('Jobs')->create(
        {
            id   => 421,
            TEST => "textmode",
        });
    $schema->resultset('Comments')->create(
        {
            job_id  => 421,
            user_id => 1,
            text    => 'poo#202',
        });
    ok($bugs->count > 0, 'Bugs available for cleanup');

    run_gru_job($app, 'limit_bugs');
    is($bugs->count, 1, 'Bugs cleaned up');
    ok($bugs->find({bugid => 'poo#202'}), 'Bug poo#202 not cleaned up due to reference from comment');
};

done_testing();
