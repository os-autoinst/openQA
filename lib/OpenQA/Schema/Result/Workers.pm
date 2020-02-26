# Copyright (C) 2015 SUSE Linux GmbH
#               2016-2020 SUSE LLC
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

package OpenQA::Schema::Result::Workers;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use DBIx::Class::Timestamps 'now';
use Try::Tiny;
use OpenQA::App;
use OpenQA::Utils 'log_error';
use OpenQA::WebSockets::Client;
use OpenQA::Constants qw(WORKERS_CHECKER_THRESHOLD DB_TIMESTAMP_ACCURACY);
use Mojo::JSON qw(encode_json decode_json);

use constant COMMANDS =>
  qw(quit abort scheduler_abort cancel obsolete livelog_stop livelog_start developer_session_start);

__PACKAGE__->table('workers');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    host => {
        data_type => 'text',
    },
    instance => {
        data_type => 'integer',
    },
    job_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
        is_nullable    => 1
    },
    upload_progress => {
        data_type   => 'jsonb',
        is_nullable => 1,
    },
    error => {
        data_type   => 'text',
        is_nullable => 1,
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(host instance)]);
# only one worker can work on a job
__PACKAGE__->add_unique_constraint([qw(job_id)]);
__PACKAGE__->belongs_to(job => 'OpenQA::Schema::Result::Jobs', 'job_id', {on_delete => 'SET NULL'});
__PACKAGE__->has_many(
    previous_jobs => 'OpenQA::Schema::Result::Jobs',
    'assigned_worker_id',
    {
        order_by => {-desc => 't_created'}});
__PACKAGE__->has_many(properties => 'OpenQA::Schema::Result::WorkerProperties', 'worker_id');

__PACKAGE__->inflate_column(
    upload_progress => {
        inflate => sub { decode_json(shift) },
        deflate => sub { encode_json(shift) },
    });

# TODO
# INSERT INTO workers (id, t_created) VALUES(0, datetime('now'));

sub name {
    my ($self) = @_;
    return $self->host . ":" . $self->instance;
}

sub seen {
    my ($self, $workercaps, $error) = @_;
    $self->update({t_updated => now()});
    $self->update_caps($workercaps) if $workercaps;
}

# update worker's capabilities
# param: workerid , workercaps
sub update_caps {
    my ($self, $workercaps) = @_;

    for my $cap (keys %{$workercaps}) {
        $self->set_property(uc $cap, $workercaps->{$cap}) if $workercaps->{$cap};
    }
}

sub all_properties {
    map { $_->key => $_->value } shift->properties->all();
}

sub get_property {
    my ($self, $key) = @_;

    my $r = $self->properties->find({key => $key});
    return $r ? $r->value : undef;
}

sub delete_properties {
    my ($self, $keys) = @_;

    return $self->properties->search({key => {-in => $keys}})->delete;
}

sub set_property {

    my ($self, $key, $val) = @_;

    my $r = $self->properties->find_or_new(
        {
            key => $key
        });

    if (!$r->in_storage) {
        $r->value($val);
        $r->insert;
    }
    else {
        $r->update({value => $val});
    }
}

sub dead {
    my ($self) = @_;

    my $dt = DateTime->now(time_zone => 'UTC');
    # check for workers active in last WORKERS_CHECKER_THRESHOLD
    # last seen should be updated at least in MAX_TIMER t in worker
    # and should not be greater than WORKERS_CHECKER_THRESHOLD.
    $dt->subtract(seconds => WORKERS_CHECKER_THRESHOLD - DB_TIMESTAMP_ACCURACY);

    $self->t_updated < $dt;
}

sub websocket_api_version {
    my ($self) = @_;

    # Cache this value. To avoid keeping querying the DB.
    unless ($self->{_websocket_api_version_}) {
        $self->{_websocket_api_version_} = $self->get_property('WEBSOCKET_API_VERSION');
    }

    return $self->{_websocket_api_version_};
}

sub check_class {
    my ($self, $class) = @_;

    unless ($self->{_worker_class_hash}) {
        for my $k (split /,/, ($self->get_property('WORKER_CLASS') || 'NONE')) {
            $self->{_worker_class_hash}->{$k} = 1;
        }
    }
    return defined $self->{_worker_class_hash}->{$class};
}

sub currentstep {
    my ($self) = @_;

    return unless ($self->job);
    my $r = $self->job->modules->find({result => 'running'}, {order_by => {-desc => 't_updated'}, rows => 1});
    $r->name if $r;
}

sub status {
    my ($self) = @_;

    return 'dead'    if ($self->dead);
    return 'broken'  if ($self->error);
    return 'running' if ($self->job);
    return 'idle';
}

sub unprepare_for_work {
    my $self = shift;

    $self->delete_properties([qw(JOBTOKEN WORKER_TMPDIR)]);
    $self->update({upload_progress => undef});

    return $self;
}

sub info {
    my $self = shift;
    my ($live) = ref $_[0] eq "HASH" ? @{$_[0]}{qw(live)} : @_;

    my $settings = {
        id       => $self->id,
        host     => $self->host,
        instance => $self->instance,
        status   => $self->status,
        error    => $self->error,
    };
    $settings->{properties} = {};
    for my $p ($self->properties->all) {
        $settings->{properties}->{$p->key} = $p->value;
    }
    # puts job id in status, otherwise is idle
    my $job = $self->job;
    if ($job) {
        $settings->{jobid} = $job->id;
        my $cs = $self->currentstep;
        $settings->{currentstep} = $cs if $cs;
    }
    my $alive = $settings->{alive} = $settings->{connected} = $self->dead ? 0 : 1;
    $settings->{websocket} = $live ? $alive : 0;

    # note: The keys "connected" and "websocket" are only provided for compatibility. The "live"
    #       parameter makes no actual difference anymore. (`t_updated` is decrease when a worker
    #       disconnects from the ws server so relying on it is as live as it gets.)

    return $settings;
}

sub send_command {
    my ($self, %args) = @_;
    return undef if (!defined $args{command});

    if (!grep { $args{command} eq $_ } COMMANDS) {
        my $msg = 'Trying to issue unknown command "%s" for worker "%s:%n"';
        log_error(sprintf($msg, $args{command}, $self->host, $self->instance));
        return undef;
    }

    try {
        OpenQA::App->singleton->emit_event(
            openqa_command_enqueue => {workerid => $self->id, command => $args{command}});
    };

    # prevent ws server querying itself (which would cause it to hang until the connection times out)
    if (OpenQA::WebSockets::Client::is_current_process_the_websocket_server) {
        return OpenQA::WebSockets::ws_send($self->id, $args{command}, $args{job_id}, undef);
    }

    my $client = OpenQA::WebSockets::Client->singleton;
    try { $client->send_msg($self->id, $args{command}, $args{job_id}) }
    catch {
        log_error(
            sprintf(
                'Failed dispatching message to websocket server over ipc for worker "%s:%n": %s',
                $self->host, $self->instance, $_
            ));
        return undef;
    };
    return 1;
}

sub to_string {
    my ($self) = @_;

    return $self->host . ':' . $self->instance;
}

sub unfinished_jobs {
    my ($self) = @_;

    return $self->previous_jobs->search({t_finished => undef});
}

sub set_current_job {
    my ($self, $job) = @_;
    $self->update({job_id => $job->id});
}

1;
