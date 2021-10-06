# Copyright 2020 SUSE LLC
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

package OpenQA::Worker::App;
use Mojo::Base 'Mojolicious';

has [qw(log_name level instance log_dir)];

# This is a mock application, so OpenQA::Setup can be reused to set up logging
# for the workers
sub startup {
    my $self = shift;
    $self->mode('production');
}

1;
