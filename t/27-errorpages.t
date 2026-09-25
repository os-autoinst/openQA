# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use Test::Mojo;
use Test::Warnings ':report_warnings';
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';

# init test case
my $test_case = OpenQA::Test::Case->new;
$test_case->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

subtest '404 error page' => sub {
    $t->get_ok('/unavailable_page')->status_is(404);
    my $dom = $t->tx->res->dom;
    is_deeply [$dom->find('h1')->map('text')->each], ['Page not found'], 'correct page';
    is_deeply [$dom->find('h2')->map('text')->each], ['Available routes'], 'available routes shown';
    ok index($t->tx->res->text, 'Each entry contains the') >= 0, 'description shown';
};

subtest 'error pages shown for OpenQA::WebAPI::Controller::Step' => sub {
    my $schema = $t->app->schema;
    my $job = $schema->resultset('Jobs')->find(99946);
    my $real_needle_dir = Mojo::File->new($job->needle_dir)->realpath->to_string;
    my $dir = $schema->resultset('NeedleDirs')->find_or_create(
        {
            path => $real_needle_dir,
            name => 'fixtures'
        });
    $schema->resultset('Needles')->find_or_create(
        {
            dir_id => $dir->id,
            filename => 'inst-timezone-text.json',
        });

    my $existing_job = 99946;
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1")->status_is(302, 'redirection');

    my $needle_path = "$real_needle_dir/inst-timezone-text.json";
    Mojo::File->new($real_needle_dir)->make_path;
    Mojo::File->new('t/data/default-needle.json')->copy_to($needle_path);

    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1", {'X-Requested-With' => 'XMLHttpRequest'})
      ->status_is(200, 'step viewimg loads with needle present')
      ->content_like(qr/inst-timezone-text/, 'needle name is shown')
      ->content_unlike(qr/<span class="badge bg-danger text-light ms-1">deleted<\/span>/,
        'needle is not marked deleted')
      ->content_like(qr/inst-timezone-text.*show-needle-info/s, 'needle info action icon is displayed');

    unlink $needle_path or die "Failed to remove needle: $!";

    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1", {'X-Requested-With' => 'XMLHttpRequest'})
      ->status_is(200, 'step viewimg loads with deleted needle')
      ->content_like(qr/inst-timezone-text/, 'needle name is shown')
      ->content_like(qr/<span class="badge bg-danger text-light ms-1">deleted<\/span>/, 'needle is marked deleted')
      ->content_unlike(qr/inst-timezone-text.*show-needle-info/s, 'needle info action icon is hidden');
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1/src")->status_is(200)
      ->content_type_is('text/html;charset=UTF-8');
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1/src.txt")->status_is(200)
      ->content_type_is('text/plain;charset=UTF-8');
    $t->get_ok("/tests/$existing_job/modules/installer_timezone/steps/1/edit")->status_is(200);

    subtest 'get error 404 if job or module not found' => sub {
        my $non_existing_job = 99999;
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1")->status_is(302, 'redirection');
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1",
            {'X-Requested-With' => 'XMLHttpRequest'})->status_is(404);
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1/src")->status_is(404);
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1/src.txt")->status_is(404);
        $t->get_ok("/tests/$non_existing_job/modules/installer_timezone/steps/1/edit")->status_is(404);
        $t->get_ok("/tests/$existing_job/modules/nonexistingmodule/steps/1/src")->status_is(404);
        $t->get_ok("/tests/$existing_job/modules/nonexistingmodule/steps/1/src.txt")->status_is(404);
        $t->get_ok("/tests/$existing_job/modules/nonexistingmodule/steps/1/edit")->status_is(404);
    };
};


done_testing;
