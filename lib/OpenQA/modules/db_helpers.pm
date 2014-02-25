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

package db_helpers;

sub _create_timestamp_trigger
{
    my $schema = shift;
    my $table = shift;
    my $action = shift;

    my $timestamp;
    if ($action eq 'UPDATE') {
        $timestamp = 't_updated';
    } elsif ($action eq 'INSERT') {
        $timestamp = 't_created';
    } else {
        die "invalid action, must be INSERT or UPDATE\n";
    }

    $schema->add_trigger(
        name                => 'trigger_'.$table.'_'.$timestamp,
        perform_action_when => 'AFTER',
        database_events     => [$action],
        fields              => [$timestamp],
        on_table            => $table,
        action              => "UPDATE $table SET $timestamp = datetime('now') WHERE id = NEW.id;",
        schema              => $schema,
    );

}

sub create_auto_timestamps
{
    my $schema = shift;
    my $table = shift;

    _create_timestamp_trigger($schema, $table, 'INSERT');
    _create_timestamp_trigger($schema, $table, 'UPDATE');
}

1;
