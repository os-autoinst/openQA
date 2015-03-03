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
    unshift @INC, 'lib';
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
$get->content_like(qr/passed: 2,\s*failed: 0,\s*unknown: 0,\s*incomplete: 0,\s*scheduled: 2,\s*running: 2,\s*none: 1/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_i586');
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists('#flavor_GNOME-Live_arch_i686');
$get->element_exists_not('#flavor_GNOME-Live_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->element_exists('#res_DVD_i586_kde span.result_passed');
$get->element_exists('#res_GNOME-Live_i686_RAID0 i.state_cancelled');
$get->element_exists('#res_DVD_i586_RAID1 i.state_scheduled');
$get->element_exists_not('#res_DVD_x86_64_doc');

#
# Overview of build 0048
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '0048'});
$get->status_is(200);
$get->content_like(qr/passed: 0,\s*failed: 1,\s*unknown: 0,\s*incomplete: 0,\s*scheduled: 0,\s*running: 0,\s*none: 0/i);

# Check the headers
$get->element_exists('#flavor_DVD_arch_x86_64');
$get->element_exists_not('#flavor_DVD_arch_i586');
$get->element_exists_not('#flavor_GNOME-Live_arch_i686');

# Check some results (and it's overview_xxx classes)
$get->element_exists('#res_DVD_x86_64_doc span.result_failed');
$get->element_exists_not('#res_DVD_i586_doc');
$get->element_exists_not('#res_DVD_i686_doc');
$get->element_exists_not('#res_DVD_x86_64_kde');

#
# Default overview for 13.1
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => '13.1'});
$get->status_is(200);
$get->content_like(qr/current results for.*opensuse 13\.1 build 0091/i);
$get->content_like(qr/passed: 2,\s*failed: 0,\s*unknown: 0,\s*incomplete: 0,\s*scheduled: 2,\s*running: 2,\s*none: 1/i);

#
# Default overview for Factory
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory'});
$get->status_is(200);
$get->content_like(qr/current results for.*opensuse Factory build 0048/i);
$get->content_like(qr/passed: 0,\s*failed: 1,\s*unknown: 0,\s*incomplete: 0,\s*scheduled: 0,\s*running: 0,\s*none: 0/i);


#
# Still possible to check an old build
#
$get = $t->get_ok('/tests/overview' => form => {distri => 'opensuse', version => 'Factory', build => '87.5011'});
$get->status_is(200);
$get->content_like(qr/current results for.*opensuse Factory build 87.5011/i);
$get->content_like(qr/passed: 0,\s*failed: 0,\s*unknown: 0,\s*incomplete: 1,\s*scheduled: 0,\s*running: 0,\s*none: 0/i);

done_testing();
