#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -signatures;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '15';

my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

use Test::MockModule;
my $mock_gru = Test::MockModule->new('OpenQA::Shared::Plugin::Gru');
$mock_gru->redefine(
    'enqueue_and_keep_track',
    sub ($self, %args) {
        return Mojo::Promise->new->resolve({json_data => {tags => ['foo']}});
    });

subtest 'needle validation in Step controller' => sub {
    $t->post_ok('/login', form => {user => 'Demo'})->status_is(302, 'Successful login establishes user session');

    $t->get_ok('/tests/99946/modules/installer_timezone/steps/1/edit')
      ->status_is(200, 'Successfully retrieve edit page');
    my $csrf = $t->tx->res->dom->at('meta[name="csrf-token"]')->attr('content');
    ok $csrf, 'Found CSRF token in meta tag';

    my $post_save = sub ($name, $json) {
        return $t->post_ok(
            '/tests/99946/modules/installer_timezone/steps/1/',
            {'X-CSRF-TOKEN' => $csrf},
            form => {
                needlename => $name,
                imagename => "$name.png",
                json => $json,
            });
    };

    $post_save->('firefox_pdf-firefox-pdf-page-20260813-sle12', '{"area": [{"type": "match"}], "tags": ["tag1"]}')
      ->status_is(200, 'Accept invalid needle filename when validation is disabled (default)')
      ->json_is('/json_data/tags/0', 'foo', 'Verify successful save enqueued task');

    $t->app->config->{needles} = {
        validation => 'block',
        validation_rules => 'timestamp,workaround_bugref,single_click_area',
    };

    $post_save->('firefox_pdf-firefox-pdf-page-20260813-sle12', '{"area": [{"type": "match"}], "tags": ["tag1"]}')
      ->status_is(400, 'Reject invalid name and return HTTP 400 when block mode is enabled')
      ->json_like('/error', qr/missing or invalid timestamp suffix/,
        'Verify response contains timestamp error message');

    $post_save->(
        'firefox_pdf-firefox-pdf-page-20260813',
        '{"area": [{"type": "click"}, {"type": "click"}], "tags": ["tag1"]}'
    )->status_is(400, 'Reject multiple click areas and return HTTP 400 when block mode is enabled')
      ->json_like('/error', qr/areas with type=click/, 'Verify response contains click area error message');

    $post_save->('firefox_pdf-firefox-pdf-page-20260813', '{"area": [{"type": "match"}], "tags": ["tag1"]}')
      ->status_is(200, 'Accept valid name and structure when block mode is enabled');

    $t->app->config->{needles} = {
        validation => 'warn',
        validation_rules => 'timestamp,workaround_bugref,single_click_area',
    };

    $post_save->('firefox_pdf-firefox-pdf-page-20260813-sle12', '{"area": [{"type": "match"}], "tags": ["tag1"]}')
      ->status_is(200, 'Accept invalid needle name with HTTP 200 when warn mode is enabled')->json_like(
        '/validation_warnings/0',
        qr/missing or invalid timestamp suffix/,
        'Verify response contains validation warnings'
      );
};

done_testing;
