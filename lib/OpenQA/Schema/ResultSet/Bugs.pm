# Copyright (C) 2019 LLC
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

package OpenQA::Schema::ResultSet::Bugs;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

use OpenQA::App;

# this method returns the bug if it has already been refreshed (and undef otherwise)
sub get_bug {
    my ($self, $bugid, %attrs) = @_;
    return unless $bugid;

    my $bug = $self->find_or_new({bugid => $bugid, %attrs});

    if (!$bug->in_storage) {
        $bug->insert;
        OpenQA::App->singleton->emit_event(openqa_bug_create => {id => $bug->id, bugid => $bug->bugid, implicit => 1});
    }
    elsif ($bug->refreshed && $bug->existing) {
        return $bug;
    }

    return undef;
}

1;
