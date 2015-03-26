# Copyright (C) 2015 SUSE Linux GmbH
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
use base qw/DBIx::Class::Core/;
use DBIx::Class::Timestamps qw/now/;

use db_helpers;

__PACKAGE__->table('workers');
__PACKAGE__->load_components(qw/InflateColumn::DateTime Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    host => {
        data_type => 'text',
    },
    instance => {
        data_type => 'integer',
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw/host instance/]);
__PACKAGE__->might_have(job => 'OpenQA::Schema::Result::Jobs', 'worker_id');
__PACKAGE__->has_many(properties => 'OpenQA::Schema::Result::WorkerProperties', 'worker_id');

# TODO
# INSERT INTO workers (id, t_created) VALUES(0, datetime('now'));

sub seen(;$) {
    my ($self, $workercaps) = @_;
    $self->update({ t_updated => now() });
    $self->update_caps($workercaps) if $workercaps;
}

# update worker's capabilities
# param: workerid , workercaps
sub update_caps($$) {
    my ($self, $workercaps) = @_;

    for my $cap (keys %$workercaps) {
        $self->set_property(uc $cap, $workercaps->{$cap}) if $workercaps->{$cap};
    }
}

sub get_property($) {
    my ($self, $key) = @_;

    my $r = $self->properties->find({key => $key});
    return $r ? $r->value : undef;
}

sub set_property($$) {

    my ($self, $key, $val) = @_;

    my $r = $self->properties->find_or_new(
        {
            key => $key
        }
    );

    if (!$r->in_storage) {
        $r->value($val);
        $r->insert;
    }
    else {
        $r->update({ value => $val });
    }
}

sub dead {
    my ($self) = @_;

    my $dt = DateTime->now(time_zone=>'UTC');
    # check for workers active in last 10s (last seen should be updated each 5s)
    $dt->subtract(seconds => 10);

    $self->t_updated < $dt;
}

sub currentstep {
    my ($self) = @_;

    return undef unless ($self->job);
    my $r = $self->job->modules->find({ result => 'running' });
    $r->name if $r;
}

sub status {
    my ($self) = @_;

    return "dead" if ($self->dead);

    my $job = $self->job;
    if($job) {
        return "running";
    }
    else {
        return "idle";
    }
}

sub connected {
    my ($self) = @_;
    OpenQA::WebSockets::ws_is_worker_connected($self);
}

sub info {
    my ($self) = @_;

    my $settings = {
        id => $self->id,
        host => $self->host,
        instance => $self->instance,
        status => $self->status
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
    $settings->{connected} = $self->connected;
    return $settings;
}

1;
# vim: set sw=4 et:
