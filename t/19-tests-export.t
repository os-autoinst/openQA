# Copyright 2016-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::Database;
use OpenQA::Test::TimeLimit '10';
use Test::Mojo;
use Test::Warnings ':report_warnings';

my $args;
my $schema = OpenQA::Test::Database->new->create(fixtures_glob => '01-jobs.pl');
my $t = Test::Mojo->new('OpenQA::WebAPI');

# export all jobs
$t->get_ok("/tests/export")->status_is(200)->content_type_is('text/plain')
  ->content_like(qr/Job 99937: opensuse-13.1-DVD-i586-Build0091-kde\@32bit is passed/)
  ->content_like(qr/Job 99981: opensuse-13.1-GNOME-Live-i686-Build0091-RAID0\@32bit is skipped/);

# filter
$t->get_ok("/tests/export?from=99981")->status_is(200)->content_type_is('text/plain')
  ->content_unlike(qr/Job 99937: opensuse-13.1-DVD-i586-Build0091-kde\@32bit is passed/)
  ->content_like(qr/Job 99981: opensuse-13.1-GNOME-Live-i686-Build0091-RAID0\@32bit is skipped/);

# to is exclusive
$t->get_ok("/tests/export?to=99981")->status_is(200)->content_type_is('text/plain')
  ->content_like(qr/Job 99937: opensuse-13.1-DVD-i586-Build0091-kde\@32bit is passed/)
  ->content_unlike(qr/Job 99981: opensuse-13.1-GNOME-Live-i686-Build0091-RAID0\@32bit is skipped/);

done_testing();
