# Copyright (C) 2017-2020 SUSE LLC
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
# no OpenQA::Test::TimeLimit for this trivial test

use Mojo::Base 'Mojolicious', -signatures;

use_ok('OpenQA::WebAPI::Description', qw(get_pod_from_controllers set_api_desc));
my $app = Mojolicious->new;
get_pod_from_controllers($app);

done_testing;
