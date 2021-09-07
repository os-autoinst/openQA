# Copyright (C) 2019-2021 SUSE LLC
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
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";
use Mojo::Base -signatures;
use Test::Warnings;
use OpenQA::Test::TimeLimit '60';
use OpenQA::SeleniumTest;
use OpenQA::Test::ObsRsync 'setup_obs_rsync_test';

my ($t, $tempdir) = setup_obs_rsync_test(fixtures_glob => '01-jobs.pl 03-users.pl');
driver_missing unless my $driver = call_driver();
$driver->find_element_by_class('navbar-brand')->click;
$driver->find_element_by_link_text('Login')->click;

my %params = (
    'Proj1'             => ['190703_143010', 'standard',   '',            '470.1', 99937, 'passed'],
    'Proj2::appliances' => ['no data',       'appliances', '',            ''],
    'BatchedProj'       => ['191216_150610', 'containers', '',            '4704, 4703, 470.2, 469.1'],
    'Batch1'            => ['191216_150610', 'containers', 'BatchedProj', '470.2, 469.1'],
);

foreach my $proj (sort keys %params) {
    my $ident = $proj;
    $ident =~ s/\W//g;    # remove special characters to refer UI, the same way as in template

    my ($dt, $repo, $parent, $builds_text, $test_id, $test_result) = @{$params{$proj}};
    my $projfull = $parent ? "$parent|$proj" : $proj;

    # navigate to page and mock AJAX requests
    $driver->get("/admin/obs_rsync/$parent");
    $driver->execute_script('
        window.skipObsRsyncDelay = true;
        window.ajaxRequests = [];
        $.ajax = function(data) { window.ajaxRequests.push(data); data.success({message: "fake response"}) };
    ');

    # check project name and other fields are displayed properly
    is $driver->find_element("tr#folder_$ident .project")->get_text,    $projfull, "$proj name";
    like $driver->find_element("tr#folder_$ident .lastsync")->get_text, qr/$dt/,          "$proj last sync";
    like $driver->find_element("tr#folder_$ident .testlink")->get_text, qr/$test_result/, "$proj last test result"
      if $test_result;
    is $driver->find_element("tr#folder_$ident .lastsyncbuilds")->get_text, $builds_text, "$proj sync builds";

    # at start no project fetches builds from obs
    is($driver->find_element("tr#folder_$ident .obsbuilds")->get_text, '', "$proj obs builds empty");
    my $status = $driver->find_element("tr#folder_$ident .dirtystatuscol .dirtystatus")->get_text;
    like $status, qr/dirty/, "$proj dirty status";
    like $status, qr/$repo/, "$proj repo in dirty status ($status)";
    like $status, qr/$repo/, "$proj dirty has repo";

    if ($proj eq 'Batch1') {
        # click on the various buttons within the table
        $driver->find_element("tr#folder_$ident .obsbuildsupdate")->click;
        is $driver->find_element("tr#folder_$ident .obsbuilds")->get_text, 'fake response',
          'builds update response shown';

        $driver->find_element("tr#folder_$ident .lastsyncforget")->click;
        $driver->accept_alert;
        is $driver->find_element("tr#folder_$ident .lastsync")->get_text, 'fake response', 'forget response shown';

        $driver->find_element("tr#folder_$ident .dirtystatusupdate")->click;
        is $driver->find_element("tr#folder_$ident .dirtystatuscol .dirtystatus")->get_text, 'fake response',
          'dirty status update response shown';

        my $actual_requests   = $driver->execute_script('return window.ajaxRequests;');
        my @expected_requests = (
            {method => 'POST', url => '/admin/obs_rsync/BatchedProj%7CBatch1/obs_builds_text', dataType => 'json'},
            {method => 'GET',  url => '/admin/obs_rsync/BatchedProj%7CBatch1/obs_builds_text'},
            {method => 'POST', url => '/admin/obs_rsync/BatchedProj%7CBatch1/run_last', dataType => 'json'},
            {method => 'GET',  url => '/admin/obs_rsync/BatchedProj%7CBatch1/run_last'},
            {method => 'POST', url => '/admin/obs_rsync/BatchedProj/dirty_status', dataType => 'json'},
            {method => 'GET',  url => '/admin/obs_rsync/BatchedProj/dirty_status'},
        );
        ok delete $_->{success} && delete $_->{error}, 'request has success and error handlers' for @$actual_requests;
        is_deeply $actual_requests, \@expected_requests, 'ajax requests done as expected'
          or diag explain $actual_requests;
    }
    elsif ($proj eq 'Proj1') {
        # follow link to project page and click the sync button
        $driver->find_element_by_link_text($proj)->click;
        my $sync_button = $driver->find_element_by_class('btn-warning');
        is $sync_button->get_attribute('data-posturl'), '/admin/obs_rsync/Proj1/runs', 'post URL for sync as expected';
        $sync_button->click;
        wait_for_ajax msg => 'redirection target loaded';
        is $driver->get_title, 'openQA: OBS synchronization jobs', 'redirected to obs gru jobs page';
    }
}

done_testing();
