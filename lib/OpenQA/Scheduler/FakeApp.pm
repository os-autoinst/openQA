# Copyright (C) 2016 SUSE LLC
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

package OpenQA::Scheduler::FakeApp;
use Mojo::Log;
use strict;
use warnings;

# implementing the interface of Mojolicious we need to get the rest doing debug
sub new {
    my ($class) = @_;
    my $self = bless {}, $class;
    $self->{config} = {};
    $self->{log}    = Mojo::Log->new;
    return $self;
}

sub mode {
    my ($self) = @_;
    return 'production';
}

sub config {
    my ($self) = @_;
    return $self->{config};
}

sub log {
    my ($self) = @_;
    return $self->{log};
}

sub schema {
    my ($self) = @_;
    return OpenQA::Schema::connect_db();
}

sub log_name {
    my ($self) = @_;
    return 'scheduler';
}

# only needed to get $HOME/etc/openqa - so take /etc for scheduler
sub home {
    my ($self) = @_;
    return '/';
}

1;
