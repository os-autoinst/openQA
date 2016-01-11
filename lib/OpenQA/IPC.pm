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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::IPC;

use strict;
use warnings;

use Net::DBus;
use Net::DBus::Callback;
use Net::DBus::Binding::Watch;

use Mojo::IOLoop;
use Data::Dump qw/pp/;

use Scalar::Util qw/weaken/;

my $openqa_prefix = 'org.opensuse.openqa';
my %services      = (
    scheduler  => 'Scheduler',
    websockets => 'WebSockets',
    webapi     => 'WebAPI',
);

my %handles;

sub new {
    my ($class, $reactor, $test) = @_;
    $class = ref $class || $class;
    my $self = {};
    bless $self, $class;

    my $bus;
    if (!$test) {
        # for WebAPI and WebSockets we use Mojo with its own event loop, so use external reactor if supplied
        $bus = Net::DBus->find(nomainloop => $reactor ? 1 : 0);
    }
    else {
        $bus = Net::DBus->test;
    }
    return unless $bus;
    $self->{bus} = $bus;
    return $self;
}

sub ipc {
    CORE::state $ipc = shift->new(@_);
}

sub register_service {
    my ($self, $service) = @_;
    die "Unsupported service \"$service\"" unless $service && grep { /$service/ } keys %services;
    my $s = $self->{bus}->export_service(join('.', $openqa_prefix, $services{$service}));
    die "Failed to export service \"$service\"" unless $s;
    $self->{service}{$service} = $s;
    return $s;
}

sub manage_events {
    my ($self, $reactor, $object) = @_;
    return unless $reactor;
    if (ref($reactor) =~ /Mojo::Reactor/) {
        # Hook DBus events to Mojo::Reactor
        my $c = $self->{bus}->get_connection;
        $c->set_watch_callbacks(
            sub {
                my ($object, $watch) = @_;
                $self->_manage_watch_on($reactor, $watch);
            },
            sub {
                my ($object, $watch) = @_;
                $self->_manage_watch_off($reactor, $watch);
            },
            sub {
                my ($object, $watch) = @_;
                $self->_manage_watch_toggle($reactor, $watch);
            },
        );
        # TODO add timeout
        #             $c->set_timeout_callbacks(sub{
        #                     my ($object, $watch) = @_;
        #                     $self->_manage_timeout_on($reactor, $watch);
        #                 },
        #                 sub {return},
        #                 sub {return},
        #             );
        if ($c->can("dispatch")) {
            my $cb = Net::DBus::Callback->new(object => $c, method => "dispatch", args => []);
            $reactor->on('dbus-dispatch' => sub { $cb->invoke });
        }
        if ($c->can("flush")) {
            my $cb = Net::DBus::Callback->new(object => $c, method => "flush", args => []);
            $reactor->on('dbus-flush' => sub { $cb->invoke });
        }
    }
    else {
        die 'Unsupported reactor';
    }
}

sub _manage_watch_on {
    my ($self, $reactor, $watch) = @_;
    my $flags = $watch->get_flags;

    if ($flags & &Net::DBus::Binding::Watch::READABLE) {
        my $fh = $self->_get_fh_from_fd($watch->get_fileno);
        my $cb = Net::DBus::Callback->new(object => $watch, method => "handle", args => [&Net::DBus::Binding::Watch::READABLE]);
        # Net::DBus calls dispatch each time some event wakes it up, Mojo::Reactor does not support this kind of hooks
        $reactor->io($fh => sub { my ($self, $writable) = @_; $cb->invoke; $self->emit('dbus-dispatch') });
        $reactor->watch($fh, $watch->is_enabled, 0);
    }
    if ($flags & &Net::DBus::Binding::Watch::WRITABLE) {
        my $fh = $self->_get_fh_from_fd($watch->get_fileno, 1);
        my $cb = Net::DBus::Callback->new(object => $watch, method => "handle", args => [&Net::DBus::Binding::Watch::WRITABLE]);
        # Net::DBus calls flush event each time some event wakes it up, Mojo::Reactor does not support this kind of hooks
        $reactor->io($fh => sub { my ($self, $writable) = @_; $cb->invoke; $self->emit('dbus-flush') });
        $reactor->watch($fh, 0, $watch->is_enabled);
    }
}

sub _manage_watch_off {
    my ($self, $reactor, $watch) = @_;
    my $flags = $watch->get_flags;
    my ($fh, $rw);

    if ($flags & &Net::DBus::Binding::Watch::READABLE) {
        $fh = $self->_get_fh_from_fd($watch->get_fileno);
        $rw = '<';
        $reactor->remove($fh);
    }
    if ($flags & &Net::DBus::Binding::Watch::WRITABLE) {
        $fh = $self->_get_fh_from_fd($watch->get_fileno, 1);
        $rw = '>';
        $reactor->remove($fh);
    }
    close $fh;
    delete $self->{handles}{$rw}{$watch->get_fileno};
}

sub _manage_watch_toggle {
    my ($self, $reactor, $watch) = @_;
    my $flags = $watch->get_flags;

    if ($flags & &Net::DBus::Binding::Watch::READABLE) {
        my $fh = $self->{handles}{'<'}{$watch->get_fileno};
        if (defined $fh) {
            $reactor->watch($fh, $watch->is_enabled, 0);
        }
    }
    if ($flags & &Net::DBus::Binding::Watch::WRITABLE) {
        my $fh = $self->{handles}{'>'}{$watch->get_fileno};
        if (defined $fh) {
            $reactor->watch($fh, 0, $watch->is_enabled);
        }
    }
}

sub _manage_timeout_on {

}

sub _manage_timeout_off {

}

# Mojo::Reactor works with filehandles instead of descriptors
sub _get_fh_from_fd {
    my ($self, $fd, $write) = @_;

    if ($write) {
        $write = '>';
    }
    else {
        $write = '<';
    }

    if (defined $self->{handles}{$write}{$fd}) {
        return $self->{handles}{$write}{$fd};
    }
    my $fh;
    open($fh, $write . '&', $fd) || die "unable to open fd $fd for $write";
    $self->{handles}{$write}{$fd} = $fh;
    return $fh;
}

sub _dispatch {
    my ($self, $target, $command, @data) = @_;
    my $service = $self->{bus}->get_service(join('.', $openqa_prefix, $services{$target}));
    my $object = $service->get_object('/' . $services{$target}, join('.', $openqa_prefix, $services{$target}));
    return $object->$command(@data);
}

## Helpers
# scheduler - send message to scheduler
sub scheduler {
    my ($self, @param) = @_;
    return $self->_dispatch('scheduler', @param);
}

# websockets - send message to websockets
sub websockets {
    my ($self, @param) = @_;
    return $self->_dispatch('websockets', @param);
}

# webapi - send message to WebUI/API
sub webapi {
    my ($self, @param) = @_;
    return $self->_dispatch('webapi', @param);
}

1;
# vim: set sw=4 et:
