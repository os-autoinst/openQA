# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use FindBin;
use Test::Most;
use Test::Warnings ':report_warnings';
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../../external/os-autoinst-common/lib";

use OpenQA::WebAPI::Plugin::IssueReporter::OpenSuseBugzillaUtils qw(
  get_bugzilla_url get_bugzilla_distri_name get_bugzilla_product_name
);

{

    package Test::FakeJob;
    use Mojo::Base -base;
    has FLAVOR => undef;
    has VERSION => undef;
}

subtest 'get_bugzilla_url' => sub {
    is get_bugzilla_url('sle'), 'https://bugzilla.suse.com/enter_bug.cgi', 'SLE uses bugzilla.suse.com';
    is get_bugzilla_url('opensuse'), 'https://bugzilla.opensuse.org/enter_bug.cgi',
      'openSUSE uses bugzilla.opensuse.org';
    is get_bugzilla_url('openqa'), 'https://progress.opensuse.org/projects/openqav3/issues/new',
      'Use progress for openqa button';
    is get_bugzilla_url('unknown'), 'https://bugzilla.suse.com/enter_bug.cgi', 'unknown: default (sle)';
};

subtest 'get_bugzilla_distri_name' => sub {
    is get_bugzilla_distri_name('sle'), 'SUSE Linux Enterprise', 'distri: sle->SUSE Linux Enterprise';
    is get_bugzilla_distri_name('opensuse'), 'openSUSE', 'distri: opensuse->openSUSE';
    is get_bugzilla_distri_name('alp'), 'ALP', 'distri: alp->ALP';
    is get_bugzilla_distri_name('test-unknown'), 'UNKNOWN DISTRI', 'distri: unknown->UNKNOWN DISTRI';
};

subtest 'get_bugzilla_product_name' => sub {
    my $distri = 'SUSE Linux Enterprise';

    is get_bugzilla_product_name(Test::FakeJob->new(VERSION => '15 SP3'), 'sle', \$distri), '', 'sle empty FLAVOR';
    is $distri, 'SUSE Linux Enterprise', 'sle distri_ref unchanged';

    $distri = 'SUSE Linux Enterprise';
    is get_bugzilla_product_name(Test::FakeJob->new(FLAVOR => 'Server', VERSION => '12'), 'sle', \$distri),
      'Server 12 (SLES 12)', 'sle Server 12 special-case';
    is $distri, 'SUSE Linux Enterprise', 'no PUBLIC rewrite for 12';

    $distri = 'SUSE Linux Enterprise';
    is get_bugzilla_product_name(Test::FakeJob->new(FLAVOR => 'Server', VERSION => '15 SP3'), 'sle', \$distri),
      'Server 15 SP3', 'sle public product name for 15 SP3+';
    is $distri, 'PUBLIC SUSE Linux Enterprise', 'distri_ref gets PUBLIC prefix';

    $distri = 'SUSE Linux Enterprise';
    is get_bugzilla_product_name(Test::FakeJob->new(FLAVOR => 'Server-Updates', VERSION => '15-SP3'), 'sle', \$distri),
      'Server 15 SP3', 'sle flavor suffix stripped and version "-" becomes space';
    is $distri, 'PUBLIC SUSE Linux Enterprise', 'PUBLIC rewrite still applies';

    $distri = 'SUSE Linux Enterprise';
    is get_bugzilla_product_name(Test::FakeJob->new(FLAVOR => 'WeirdFlavor', VERSION => '15 SP2'), 'sle', \$distri),
      'Server 15 SP2', 'unknown flavor falls back to Server';
    is $distri, 'SUSE Linux Enterprise', 'no PUBLIC rewrite for SP2';

    is get_bugzilla_product_name(Test::FakeJob->new(VERSION => '6.1'), 'sle-micro', undef), 'Micro 6.1', 'sle-micro';
    is get_bugzilla_product_name(Test::FakeJob->new(VERSION => 'Tumbleweed'), 'opensuse', undef), 'Tumbleweed',
      'opensuse TW';
    is get_bugzilla_product_name(Test::FakeJob->new(VERSION => 'Leap'), 'opensuse', undef), 'Distribution',
      'opensuse non-TW';
    is get_bugzilla_product_name(Test::FakeJob->new(VERSION => '4.5'), 'caasp', undef), '4', 'caasp';
    is get_bugzilla_product_name(Test::FakeJob->new(), 'openqa', undef), 'openQA', 'openqa';
    is get_bugzilla_product_name(Test::FakeJob->new(), 'test-unknown', undef), '', 'unknown';
};

done_testing;
