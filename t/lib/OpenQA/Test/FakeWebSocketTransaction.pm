# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::FakeWebSocketTransaction;
use Mojo::Base 'Mojo::EventEmitter';

use Mojo::IOLoop;
use Mojo::Message::Response;

has finish_called => 0;
has sent_messages => sub { return []; };

sub clear_messages {
    my ($self) = @_;
    $self->sent_messages([]);
}

sub is_finished {
    my ($self) = @_;
    return $self->finish_called;
}

sub is_websocket {
    my ($self) = @_;
    return 1;
}

sub send {
    my ($self, $message, $callback) = @_;

    if ($self->finish_called) {
        fail('attempt to send message via finished connection');
        return undef;
    }

    push @{$self->sent_messages}, $message;
    Mojo::IOLoop->next_tick($callback) if $callback;

    my $res = Mojo::Message::Response->new;
    $res->code(200);
    return $res;
}

sub finish {
    my ($self) = @_;
    $self->finish_called(1);
    return 1;
}

sub emit_json {
    my ($self, $json) = @_;
    return $self->emit(json => $json);
}

sub emit_finish {
    my $self = shift;
    return $self->emit(finish => @_);
}

1;
