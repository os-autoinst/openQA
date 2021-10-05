# Copyright 2018-2019 SUSE LLC
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
