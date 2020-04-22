# Copyright (C) 2016 SUSE LLC
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
use lib "$FindBin::Bin/lib";
use OpenQA::Test::Database;
use Test::Mojo;
use Test::Warnings;

my $args;

my $schema = OpenQA::Test::Database->new->create();

my $t = Test::Mojo->new('OpenQA::WebAPI');

# export all jobs
$t->get_ok("/tests/export")->status_is(200)->content_type_is('text/plain')
  ->content_like(qr/Job 99937: opensuse-13.1-DVD-i586-Build0091-kde\@32bit is passed/)
  ->content_like(qr/Job 99981: opensuse-13.1-GNOME-Live-i686-Build0091-RAID0\@32bit is skipped/);

# filter
$t->get_ok("/tests/export?from=99981")->status_is(200)->content_type_is('text/plain')
  ->content_unlike(qr/Job 99937: opensuse-13.1-DVD-i586-Build0091-kde\@32bit is passed/)
  ->content_like(qr/Job 99981: opensuse-13.1-GNOME-Live-i686-Build0091-RAID0\@32bit is skipped/);

# to is exclusiv
$t->get_ok("/tests/export?to=99981")->status_is(200)->content_type_is('text/plain')
  ->content_like(qr/Job 99937: opensuse-13.1-DVD-i586-Build0091-kde\@32bit is passed/)
  ->content_unlike(qr/Job 99981: opensuse-13.1-GNOME-Live-i686-Build0091-RAID0\@32bit is skipped/);

done_testing();
