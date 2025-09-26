#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use Mojo::Base -signatures;
use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
require OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '5';
use OpenQA::VcsProvider::GitHub;
use OpenQA::VcsProvider::Gitea;
use Test::Mojo;
use Test::Warnings ':report_warnings';

my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '03-users.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

sub test_report_status_to_git ($app, $statuses_url_key, $webhook_id) {
    # avoid making an actual query to GitHub; this test just checks whether an expected request would have been done

    my $git = OpenQA::VcsProvider->new(app => $app, type => $webhook_id);
    my $url = 'http://127.0.0.1/repos/some/repo/statuses/some-sha';
    $git->read_settings({$statuses_url_key => $url, CI_TARGET_URL => 'https://openqa.opensuse.org'});
    my $tx = $git->report_status_to_git({state => 'pending'}, '42');
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


subtest 'reporting status to GitHub' => sub {
    my $app = $t->app;
    $app->config->{secrets}->{github_token} = 'some-token';
    test_report_status_to_git($app, 'GITHUB_STATUSES_URL', 'gh:pr:123');
};

subtest 'reporting status to Gitea' => sub {
    my $app = $t->app;
    $app->config->{secrets}->{gitea_token} = 'some-token';
    test_report_status_to_git($app, 'GITEA_STATUSES_URL', 'gitea:pr:123');
};

done_testing();
