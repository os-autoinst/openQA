# Copyright (C) 2016-2017 SUSE LLC
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

package OpenQA::WebAPI::Plugin::AMQP;

use strict;
use warnings;

use parent 'Mojolicious::Plugin';
use Cpanel::JSON::XS;
use Mojo::IOLoop;
use OpenQA::Utils;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use Mojo::RabbitMQ::Client;

my @job_events     = qw(job_create job_delete job_cancel job_duplicate job_restart job_update_result job_done);
my @comment_events = qw(comment_create comment_update comment_delete);

sub new {
    my $class = shift;
    my $self  = $class->SUPER::new(@_);
    $self->{app}          = undef;
    $self->{config}       = undef;
    $self->{client}       = undef;
    $self->{channel}      = undef;
    $self->{reconnecting} = 0;
    return $self;
}

sub register {
    my $self = shift;
    $self->{app}    = shift;
    $self->{config} = $self->{app}->config;
    my $ioloop = Mojo::IOLoop->singleton;

    $ioloop->next_tick(
        sub {
            $self->connect();

            # register for events
            for my $e (@job_events) {
                $ioloop->on("openqa_$e" => sub { shift; $self->on_job_event(@_) });
            }
            for my $e (@comment_events) {
                $ioloop->on("openqa_$e" => sub { shift; $self->on_comment_event(@_) });
            }
        });
}

sub reconnect {
    my $self = shift;

    return if $self->{reconnecting};
    $self->{reconnecting} = 1;
    OpenQA::Utils::log_info("AMQP reconnecting in $self->{config}->{amqp}{reconnect_timeout} seconds");
    Mojo::IOLoop->timer(
        $self->{config}->{amqp}{reconnect_timeout} => sub {
            $self->{reconnecting} = 0;
            $self->connect();
        });
}

sub connect {
    my $self = shift;

    OpenQA::Utils::log_info("Connecting to AMQP server");
    $self->{client} = Mojo::RabbitMQ::Client->new(url => $self->{config}->{amqp}{url});
    $self->{client}->heartbeat_timeout($self->{config}->{amqp}{heartbeat_timeout} // 60);
    $self->{client}->on(
        open => sub {
            OpenQA::Utils::log_info("AMQP connection established");
            my ($client) = @_;

            $self->{channel} = Mojo::RabbitMQ::Client::Channel->new();
            $self->{channel}->catch(sub { OpenQA::Utils::log_warning("Error on AMQP channel received: " . $_[1]); });

            $self->{channel}->on(
                open => sub {
                    my ($channel) = @_;
                    $channel->declare_exchange(
                        exchange => $self->{config}->{amqp}{exchange},
                        type     => 'topic',
                        passive  => 1,
                        durable  => 1
                    )->deliver();
                });
            $self->{channel}->on(
                close => sub {
                    OpenQA::Utils::log_warning("AMQP channel closed");
                });
            $client->open_channel($self->{channel});
        });
    $self->{client}->on(
        close => sub {
            OpenQA::Utils::log_warning("AMQP connection closed");
            $self->reconnect();
        });
    $self->{client}->on(
        error => sub {
            my ($client, $error) = @_;
            OpenQA::Utils::log_warning("AMQP connection error: $error");
            $self->reconnect();
        });
    $self->{client}->on(
        disconnect => sub {
            OpenQA::Utils::log_warning("AMQP connection closed");
            $self->reconnect();
        });
    $self->{client}->on(
        timeout => sub {
            OpenQA::Utils::log_warning("AMQP connection closed");
            $self->reconnect();
        });
    $self->{client}->connect();
}

sub log_event {
    my ($self, $event, $event_data) = @_;

    unless ($self->{channel} && $self->{channel}->is_open) {
        OpenQA::Utils::log_warning("Error sending AMQP event: Channel is not open");
        return;
    }

    # use dot separators
    $event =~ s/_/\./;
    $event =~ s/_/\./;

    my $topic = $self->{config}->{amqp}{topic_prefix} . '.' . $event;

    # convert data to JSON, with reliable key ordering (helps the tests)
    $event_data = Cpanel::JSON::XS->new->canonical(1)->allow_blessed(1)->ascii(1)->encode($event_data);

    OpenQA::Utils::log_debug("Sending AMQP event: $topic");

    $self->{channel}->publish(
        exchange    => $self->{config}->{amqp}{exchange},
        routing_key => $topic,
        body        => $event_data
    )->deliver();
}

sub on_job_event {
    my ($self, $args) = @_;
    my ($user_id, $connection_id, $event, $event_data) = @$args;

    # find count of pending jobs for the same build
    # this is so we can tell when all tests for a build are done
    my $job = $self->{app}->db->resultset('Jobs')->find({id => $event_data->{id}});
    my $build = $job->BUILD;
    $event_data->{group_id}  = $job->group_id;
    $event_data->{remaining} = $self->{app}->db->resultset('Jobs')->search(
        {
            'me.BUILD' => $build,
            state      => [OpenQA::Jobs::Constants::PENDING_STATES],
        })->count;
    # add various useful properties for consumers if not there already
    for my $detail (qw(BUILD TEST ARCH MACHINE FLAVOR)) {
        $event_data->{$detail} //= $job->$detail;
    }
    for my $detail (qw(ISO HDD_1)) {
        $event_data->{$detail} //= $job->settings_hash->{$detail} if ($job->settings_hash->{$detail});
    }

    $self->log_event($event, $event_data);
}

sub on_comment_event {
    my ($self, $args) = @_;
    my ($comment_id, $connection_id, $event, $event_data) = @$args;

    # find comment in database
    my $comment = $self->{app}->db->resultset('Comments')->find($event_data->{id});
    return unless $comment;

    # just send the hash already used for JSON representation
    my $hash = $comment->hash;
    # also include comment id, job_id, and group_id
    $hash->{id}       = $comment->id;
    $hash->{job_id}   = $comment->job_id;
    $hash->{group_id} = $comment->group_id;

    $self->log_event($event, $hash);
}

1;
