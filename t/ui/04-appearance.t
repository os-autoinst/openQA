# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $season = $t->app->is_seasonal_period ? 'true' : 'false';

sub check_form ($theme, $mode) {
    $t->get_ok('/appearance')->status_is(200)->element_exists(qq{select#theme option[selected][value="$theme"]})
      ->element_exists(qq{select#seasonal_decorations option[selected][value="$mode"]});
}

sub check_page ($theme, $enabled, $overlay) {
    $t->get_ok('/')->status_is(200)->element_exists(qq{html[data-theme-preference="$theme"]})
      ->element_exists(qq{html[data-seasonal-decorations="$enabled"]});
    if ($overlay) {
        $t->element_exists('div#halloween-overlay');
    }
    else {
        $t->element_exists_not('div#halloween-overlay');
    }
}

subtest 'No login, no themes' => sub {
    $t->get_ok('/appearance')->status_is(302);
};

subtest 'Login as Percival' => sub {
    $t->get_ok('/tests');
    $test_case->login($t, 'percival');
    $t->ua->max_redirects(5);
};

subtest 'Default is light theme with seasonal decorations enabled during October' => sub {
    check_form('light', 'auto');
    check_page('light', $season, 0);
};

subtest 'Explicit dark theme gets decorations during October' => sub {
    $t->post_ok('/appearance' => form => {theme => 'dark', seasonal_decorations => 'auto'})->status_is(200);
    check_form('dark', 'auto');
    check_page('dark', $season, $season eq 'true');
};

subtest 'Theme detection is resolved by the browser, so the markup is shipped during October' => sub {
    $t->post_ok('/appearance' => form => {theme => 'detect', seasonal_decorations => 'auto'})->status_is(200);
    check_form('detect', 'auto');
    check_page('detect', $season, $season eq 'true');
};

subtest 'Seasonal decorations can be enabled all year' => sub {
    $t->post_ok('/appearance' => form => {theme => 'dark', seasonal_decorations => 'on'})->status_is(200);
    check_form('dark', 'on');
    check_page('dark', 'true', 1);
};

subtest 'Seasonal decorations can be disabled' => sub {
    $t->post_ok('/appearance' => form => {theme => 'dark', seasonal_decorations => 'off'})->status_is(200);
    check_form('dark', 'off');
    check_page('dark', 'false', 0);
};

subtest 'Seasonal decorations are not shown in light mode' => sub {
    $t->post_ok('/appearance' => form => {theme => 'light', seasonal_decorations => 'on'})->status_is(200);
    check_form('light', 'on');
    check_page('light', 'true', 0);
};

subtest 'Omission of seasonal_decorations preserves existing preference' => sub {
    $t->post_ok('/appearance' => form => {theme => 'dark'})->status_is(200);
    check_form('dark', 'on');
    check_page('dark', 'true', 1);
};

subtest 'Seasonal decoration labels are sentence case' => sub {
    $t->get_ok('/appearance')->status_is(200);
    is $t->tx->res->dom->at('label[for=seasonal_decorations]')->text, 'Seasonal decorations', 'label is sentence case';
    is $t->tx->res->dom->at('select#seasonal_decorations option[value=auto]')->text,
      'Automatically during October', 'auto option is sentence case';
};

subtest 'Invalid parameters are rejected' => sub {
    $t->post_ok('/appearance' => form => {theme => 'dark', seasonal_decorations => 'bogus'})->status_is(500);
    $t->post_ok('/appearance' => form => {theme => 'bogus', seasonal_decorations => 'auto'})->status_is(500);
    check_form('dark', 'on');
};

done_testing();
