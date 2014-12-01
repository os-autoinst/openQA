# Copyright (C) 2014 SUSE Linux Products GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

BEGIN {
    unshift @INC, 'lib', 'lib/OpenQA/modules';
}

use Mojo::Base -strict;
use Test::More;
use Test::Mojo;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data;

my $t = Test::Mojo->new('OpenQA');

#
# Overview with incorrect parameters
#
$t->get_ok('/tests/overview')->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091'})->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091', distri => 'opensuse'})->status_is(404);
$t->get_ok('/tests/overview' => form => {build => '0091', version => '13.1'})->status_is(404);

#
# Overview of build 0091
#
my $get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1', build => '0091'});
$get->status_is(200);

$get->content_like(qr/current results for.*opensuse 13\.1 build 0091/i);
$get->content_like(qr/passed: 2, failed: 0, unknown: 0, incomplete: 0, scheduled: 2, running: 1, none: 1/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_i586');
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists('#flavor_GNOME-Live_arch_i686');
$get->element_exists_not('#flavor_GNOME-Live_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->text_is('#res_DVD_i586_kde span.overview_passed a' => '48/0/3');
$get->text_is('#res_GNOME-Live_i686_RAID0 span' => 'cancelled');
$get->text_is('#res_DVD_i586_RAID1 span' => 'sched.(46)');
$get->element_exists_not('#res_DVD_x86_64_doc');

#
# Overview of build 0048
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048'});
$get->status_is(200);
$get->content_like(qr/passed: 0, failed: 1, unknown: 0, incomplete: 0, scheduled: 0, running: 0, none: 0/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i586');
$get->element_exists_not('#flavor_GNOME-Live_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->text_is('#res_DVD_x86_64_doc span.overview_failed a' => '7/0/2');
$get->element_exists_not('#res_DVD_i586_doc');
$get->element_exists_not('#res_DVD_i686_doc');
$get->element_exists_not('#res_DVD_x86_64_kde');

#
# Default overview for 13.1
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1'});
$get->status_is(200);
$get->content_like(qr/current results for.*opensuse 13\.1 build 0091/i);
$get->content_like(qr/passed: 2, failed: 0, unknown: 0, incomplete: 0, scheduled: 2, running: 1, none: 1/i);

#
# Default overview for Factory
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory'});
$get->status_is(200);
$get->content_like(qr/current results for.*opensuse Factory build 0048/i);
$get->content_like(qr/passed: 0, failed: 1, unknown: 0, incomplete: 0, scheduled: 0, running: 0, none: 0/i);


#
# Still possible to check an old build
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '87.5011'});
$get->status_is(200);
$get->content_like(qr/current results for.*opensuse Factory build 87.5011/i);
$get->content_like(qr/passed: 0, failed: 0, unknown: 0, incomplete: 1, scheduled: 0, running: 0, none: 0/i);

done_testing();
