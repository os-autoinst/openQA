# Copyright (C) 2017 SUSE LLC
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

package OpenQA::Parser::Result::Test;
use Mojo::Base -base;

has flags => sub { {} };
has [qw(category name script)];

sub to_hash {
    {
        category => $_[0]->category(),
        name     => $_[0]->name(),
        flags    => $_[0]->flags(),
        script   => $_[0]->script() // 'unk',
    };
}

1;
