# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Test::Warnings ':report_warnings';

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '6';
use Mojo::Base -signatures;
use Test::MockModule;
use OpenQA::Script::CloneJobSUSE;
use Mojo::URL;

# define fake client
{
    package Test::FakeLWPUserAgentMirrorResult;
    use Mojo::Base -base, -signatures;
    has is_success => 1;
}
{
    package Test::FakeLWPUserAgent;
    use Mojo::Base -base, -signatures;
    has is_validrepo => 1;
    sub get ($self, $url) { Test::FakeLWPUserAgentMirrorResult->new(is_success => $self->is_validrepo) }
}

subtest 'maintenance update detect' => sub {
    my $job_id = 1;
    my %job = (
        id => $job_id,
        SCC_ADDONS => "we,sdk",
        WE_TEST_REPOS => "http://foo/WE_suse/openqa,http://foo/WE_suse_2/openqa",
        SDK_TEST_REPOS => "http://foo/SDK_suse/openqa,http://foo/SDK_suse_2/openqa",
    );
    my %incident_job = (
        id => $job_id,
        INCIDENT_REPO => "http://foo/incident_repo/openqa,http://foo/incident_repo_1/openqa",
    );
    my %skip_check = (
        id => $job_id,
        SKIP_MAINTENANCE_UPDATES => "1"
    );
    my $fake_ua = Test::FakeLWPUserAgent->new;
    my %url_handler = (remote_url => Mojo::URL->new('http://foo'), ua => $fake_ua);
    my $clone_mock = Test::MockModule->new('OpenQA::Script::CloneJobSUSE');
    $fake_ua->is_validrepo(1);
    lives_ok { detect_maintenance_update($job_id, \%url_handler, \%job) } 'Maintenance updates are available';
    lives_ok { detect_maintenance_update($job_id, \%url_handler, \%incident_job) } 'Maintenance updates are available';
    $fake_ua->is_validrepo(0);
    throws_ok { detect_maintenance_update($job_id, \%url_handler, \%job) } qr/Current job $job_id will fail/,
      'Maintenance updates have been released';
    throws_ok { detect_maintenance_update($job_id, \%url_handler, \%incident_job) } qr/Current job $job_id will fail/,
      'Maintenance updates have been released';
    lives_ok { detect_maintenance_update($job_id, \%url_handler, \%skip_check) } 'Skip updates check';
};

subtest 'similar but invalid settings' => sub {
    my $job_id = 1;
    my %job = (
        id => $job_id,
        XXX_SCC_ADDONS => "we,sdk",
    );
    my %incident_job = (
        id => $job_id,
        XXX_INCIDENT_REPO => "http://foo/incident_repo/openqa,http://foo/incident_repo_1/openqa",
    );
    my $fake_ua = Test::FakeLWPUserAgent->new;
    my %url_handler = (remote_url => Mojo::URL->new('http://foo'), ua => $fake_ua);
    my $clone_mock = Test::MockModule->new('OpenQA::Script::CloneJobSUSE');
    $fake_ua->is_validrepo(0);
    lives_ok { detect_maintenance_update($job_id, \%url_handler, \%job) } 'Addon-like setting ignored';
    lives_ok { detect_maintenance_update($job_id, \%url_handler, \%incident_job) } 'Incident-like setting ignored';
};

done_testing();
