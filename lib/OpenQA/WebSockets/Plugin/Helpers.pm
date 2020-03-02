# Copyright (C) 2019 SUSE LLC
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

package OpenQA::WebSockets::Plugin::Helpers;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Schema;
use OpenQA::WebSockets::Model::Status;

sub register {
    my ($self, $app) = @_;

    $app->helper(log_name => sub { 'websockets' });

    $app->helper(schema => sub { OpenQA::Schema->singleton });
    $app->helper(status => sub { OpenQA::WebSockets::Model::Status->singleton });
}

1;
