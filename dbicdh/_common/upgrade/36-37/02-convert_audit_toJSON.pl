# Copyright © 2016 SUSE LLC
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

use strict;
use warnings;
use OpenQA::Schema;
use Safe;
use JSON ();

sub {
    my $schema = shift;

    my $event_data = $schema->resultset('AuditEvents')->search(undef, {columns => ['id', 'event_data']});
    return unless $event_data;

    # instead of eval use safe and restrict the environment only to needed operations
    my $cpt = Safe->new();
    $cpt->permit_only(':base_core', ':base_mem', ':base_orig');

    # allow nonref to allow encoding of scalars
    my $json = JSON->new();
    $json->allow_nonref(1);

    while (my $event = $event_data->next) {
        if ($event->event_data) {
            my $data = $cpt->reval($event->event_data);
            if (!$data) {
                # it was either plain string or it was trying to do something using blocked opcodes
                # encode as is
                $data = $event->event_data;
            }
            $data = $json->encode($data);
            $event->update({event_data => $data});
        }
    }
  }
