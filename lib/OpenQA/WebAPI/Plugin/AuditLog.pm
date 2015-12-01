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

my @table_events       = qw/table_create table_update table_delete/;
my @job_events         = qw/job_create job_delete job_grab job_cancel job_duplicate job_restart jobs_restart job_update_result job_set_waiting job_set_running job_done/;
my @jobgroup_events    = qw/jobgroup_create jobgroup_connect/;
my @jobtemplate_events = qw/jobtemplate_create jobtemplate_delete/;
my @user_events        = qw/user_update user_login user_comment/;
my @asset_events       = qw/asset_register asset_delete/;
my @iso_events         = qw/iso_create iso_delete iso_cancel/;
my @worker_events      = qw/command_enqueue worker_register/;
my @needle_events      = qw/needle_modify needle_delete/;


sub register {
    my ($self, $app, $reactor) = @_;
    $self->{audit_log} = $app->config->{logging}->{audit_log};

    # add table events
    for my $event (@table_events, @job_events, @jobgroup_events, @jobtemplate_events, @user_events, @asset_events, @iso_events, @worker_events, @needle_events) {
        $reactor->on("openqa_$event" => sub { shift; $self->on_event(@_) });
    }

    # add global mojolicious events
    $reactor->on('finish' => sub { $self->append_auditlog('exiting openQA') });
    $self->append_auditlog('openQA started, auditing initialized');
}

# table events
sub on_event {
    my ($self, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;
    # no need to log openqa_ prefix in openqa log
    $event =~ s/^openqa_//;
    #$self->db->resultset('AuditEvents')->create( {user_id => $user_id, connection_id => $connection_id, event => $event, event_data => pp($event_data)} );
    $self->append_auditlog("${user_id}:${connection_id} - $event - " . pp($event_data || ''));
}

sub append_auditlog {
    my $self = shift;
    die 'Wrong append call' unless $self;
    my $auditfh;
    return unless open($auditfh, '>>', $self->{audit_log});
    my $line = '[' . localtime(time) . '] ' . join "\n", @_, '';
    flock $auditfh, LOCK_EX;
    print $auditfh $line;
    flock $auditfh, LOCK_UN;
    close $auditfh;
}

1;
