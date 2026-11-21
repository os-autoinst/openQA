#!/usr/bin/env perl
# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Mojo;
use Test::Warnings ':report_warnings';
use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use File::Temp 'tempdir';
use Mojo::File 'path';
use OpenQA::Client;
use OpenQA::Test::Utils 'generate_ssh_key';
use OpenQA::SSHKey qw(parse_public_key);
use OpenQA::Test::TimeLimit '8';
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '03-users.pl');

my $t = Test::Mojo->new('OpenQA::WebAPI');
my $app = $t->app;

my $dir = tempdir(CLEANUP => 1);
my $parsed = parse_public_key(generate_ssh_key("$dir/id"));
my $arthur = $app->schema->resultset('Users')->find({username => 'arthur'});
$arthur->ssh_keys->create(
    {public_key => $parsed->{public_key}, fingerprint => $parsed->{fingerprint}, title => 'client'});

subtest 'openqa client authenticates with an SSH key' => sub {
    my $client = OpenQA::Client->new(ssh_key => "$dir/id")->ioloop(Mojo::IOLoop->singleton);
    $t->ua($client);
    $t->app($app);
    $t->get_ok('/api/v1/auth')->status_is(200, 'signed request is accepted')->content_is('ok', 'handler reached');
    $t->get_ok('/api/v1/jobs?limit=2')->status_is(200, 'signed request with a query string is accepted');
};

subtest 'openqa client with a body is accepted' => sub {
    my $client = OpenQA::Client->new(ssh_key => "$dir/id")->ioloop(Mojo::IOLoop->singleton);
    $t->ua($client);
    $t->app($app);
    $t->post_ok('/api/v1/jobs', json => {})->status_isnt(403, 'signed POST passes the operator gate')
      ->json_has('/error', 'controller handled the request after auth');
};

done_testing();
