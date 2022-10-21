# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'No login, no themes' => sub {
    $t->get_ok('/appearance')->status_is(302);
};

subtest 'So lets grab the CSRF token and login as Percival' => sub {
    $t->get_ok('/tests');
    my $token = $t->tx->res->dom->at('meta[name=csrf-token]')->attr('content');
    $test_case->login($t, 'percival');
};

subtest 'Default theme is light' => sub {
    $t->get_ok('/appearance')->status_is(200)->element_exists('select option[selected][value="light"]');
};

subtest 'We can switch to dark theme' => sub {
    $t->ua->max_redirects(5);
    $t->get_ok('/appearance')->status_is(200)->element_exists('select option[selected][value="light"]')
      ->element_exists_not('select option[selected][value="dark"]');
    $t->post_ok('/appearance' => form => {theme => 'dark'})->status_is(200)
      ->element_exists('select option[selected][value="dark"]')
      ->element_exists_not('select option[selected][value="light"]');
    $t->get_ok('/appearance')->status_is(200)->element_exists('select option[selected][value="dark"]')
      ->element_exists_not('select option[selected][value="light"]');
};

subtest 'We can switch to theme detection' => sub {
    $t->get_ok('/appearance')->status_is(200)->element_exists('select option[selected][value="dark"]')
      ->element_exists_not('select option[selected][value="detect"]');
    $t->post_ok('/appearance' => form => {theme => 'detect'})->status_is(200)
      ->element_exists('select option[selected][value="detect"]')
      ->element_exists_not('select option[selected][value="dark"]');
    $t->get_ok('/appearance')->status_is(200)->element_exists('select option[selected][value="detect"]')
      ->element_exists_not('select option[selected][value="dark"]');
};

subtest 'We can switch back to light theme' => sub {
    $t->get_ok('/appearance')->status_is(200)->element_exists('select option[selected][value="detect"]')
      ->element_exists_not('select option[selected][value="light"]');
    $t->post_ok('/appearance' => form => {theme => 'light'})->status_is(200)
      ->element_exists('select option[selected][value="light"]')
      ->element_exists_not('select option[selected][value="detect"]');
    $t->get_ok('/appearance')->status_is(200)->element_exists('select option[selected][value="light"]')
      ->element_exists_not('select option[selected][value="detect"]');
};

done_testing();
