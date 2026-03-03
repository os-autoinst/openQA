# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::FakeWebSocketTransaction;
use Mojo::Base 'Mojo::EventEmitter', -signatures;

use Mojo::IOLoop;
use Mojo::Message::Response;

has finish_called => 0;
has sent_messages => sub { return []; };

sub clear_messages ($self) {
    $self->sent_messages([]);
}

sub is_finished ($self) {
    return $self->finish_called;
}

sub is_websocket ($self) {
    return 1;
}

sub send ($self, $message, $callback = undef) {

    if ($self->finish_called) {
        fail('attempt to send message via finished connection');    # uncoverable statement
        return undef;    # uncoverable statement
    }

    push @{$self->sent_messages}, $message;
    Mojo::IOLoop->next_tick($callback) if $callback;

    my $res = Mojo::Message::Response->new;
    $res->code(200);
    return $res;
}

sub finish ($self, $status_code = undef) {
    $self->finish_called(1);
    return 1;
}

sub emit_json ($self, $json) {
    return $self->emit(json => $json);
}

sub emit_finish ($self, @args) {
    return $self->emit(finish => @args);
}

1;
