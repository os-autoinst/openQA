#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
require OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '5';
use OpenQA::VcsProvider;
use Test::Mojo;
use Test::Warnings ':report_warnings';

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest 'reporting status to GitHub' => sub {
    # avoid making an actual query to GitHub; this test just checks whether an expected request would have been done
    my $app = $t->app;
    $app->config->{secrets}->{github_token} = 'some-token';

    my $git = OpenQA::VcsProvider->new(app => $app);
    my $url = 'http://127.0.0.1/repos/some/repo/statuses/some-sha';
    $git->read_settings({GITHUB_STATUSES_URL => $url});
    my $tx = $git->report_status_to_git({state => 'pending'}, '42', 'https://openqa.opensuse.org');
    my $req = $tx->req;
    is $req->method, 'POST', 'method';
    is $req->url, $url, 'URL';
    my %json = (
        state => 'pending',
        context => 'openqa',
        description => 'openQA test run',
        target_url => 'https://openqa.opensuse.org/admin/productlog?id=42'
    );
    is_deeply $req->json, \%json, 'payload';
    is $req->headers->header('Authorization'), 'Bearer some-token', 'authorization header';
    ok $tx->is_finished, 'transaction has finished (and thus was started in first place)';
};

done_testing();
