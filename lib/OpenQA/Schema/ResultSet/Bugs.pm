# Copyright 2019 LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::ResultSet::Bugs;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

use OpenQA::App;

# inserts the bug if it is new, returns the bug if it has been refreshed, undef otherwise
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
