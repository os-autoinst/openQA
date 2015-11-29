# Copyright (C) 2015 SUSE LLC
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

package OpenQA::WebAPI::Plugin::AuditLog;

use strict;
use warnings;

use parent qw/Mojolicious::Plugin/;
use Mojo::IOLoop;
use Data::Dump qw/pp/;
use Fcntl qw/:flock/;
use Scalar::Util qw/weaken/;

our @table_events = qw/table_create_req table_create_res table_update_req table_update_res table_delete_req table_delete_res/;

sub register {
    my ($self, $app, $reactor) = @_;
    $self->{audit_log} = $app->config->{logging}->{audit_log};

    # add table events
    for my $event (@table_events) {
        $reactor->on($event => sub { $self->on_table_event($event, @_) });
    }

    # add global mojolicious events
    $reactor->on('finish' => sub { $self->append_auditlog('exiting openQA') });
    $self->append_auditlog('openQA started, auditing initialized');
}

# table events
sub on_table_event {
    my ($self, $table_event, $e, $args) = @_;
    my ($user_id, $connection_id, $event_data) = @$args;
    #$self->db->resultset('AuditLog')->create( {user_id => $user_id, connection_id => $connection_id, event => $event, event_data => pp($event_data)} );
    $self->append_auditlog("${user_id}:${connection_id} - $table_event - " . pp($event_data));
}

# job events

sub append_auditlog {
    my $self = shift;
    die 'Wrong append call' unless $self;
    my $auditfh;
    return unless open($auditfh, '>>', $self->{audit_log});
    my $line = '[' . localtime(time) . '] ' . join "\n", @_, '';
    flock $auditfh, LOCK_EX;
    print $auditfh $line;
    flock $auditfh, LOCK_UN;
    close($auditfh);
}

1;
