# Copyright 2015-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Plugin::AuditLog;
use Mojo::Base 'Mojolicious::Plugin';

use Mojo::IOLoop;
use Mojo::JSON 'to_json';
use OpenQA::Events;

my @table_events = qw(table_create table_update table_delete);
my @job_events = qw(job_create job_delete job_cancel job_restart jobs_restart job_update_result
  job_done job_grab job_cancel_by_settings);
my @jobgroup_events = qw(jobgroup_create jobgroup_update jobgroup_delete jobgroup_connect);
my @jobtemplate_events = qw(jobtemplate_create jobtemplate_delete);
my @user_events = qw(user_update user_login user_new_comment user_update_comment user_delete_comment user_deleted);
my @asset_events = qw(asset_register asset_delete);
my @iso_events = qw(iso_create iso_delete iso_cancel);
my @worker_events = qw(command_enqueue worker_register worker_delete);
my @needle_events = qw(needle_modify needle_delete);

# disabled events:
# job_grab

sub register {
    my ($self, $app) = @_;

    # register for events
    my @events = (
        @table_events, @job_events, @jobgroup_events, @jobtemplate_events, @user_events,
        @asset_events, @iso_events, @worker_events, @needle_events
    );
    # filter out events on blocklist
    my @blocklist = split / /, $app->config->{audit}{blocklist};
    for my $e (@blocklist) {
        @events = grep { $_ ne $e } @events;
    }
    for my $e (@events) {
        OpenQA::Events->singleton->on("openqa_$e" => sub { shift; $self->on_event($app, @_) });
    }

    # log restart
    my $schema = $app->schema;
    my $user = $schema->resultset('Users')->find({username => 'system'});
    $schema->resultset('AuditEvents')
      ->create({user_id => $user->id, connection_id => 0, event => 'startup', event_data => 'openQA restarted'});
}

# table events
sub on_event {
    my ($self, $app, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;
    # no need to log openqa_ prefix in openqa log
    $event =~ s/^openqa_//;
    $app->schema->resultset('AuditEvents')->create(
        {
            user_id => $user_id,
            connection_id => $connection_id,
            event => $event,
            event_data => to_json($event_data)});
}

1;
