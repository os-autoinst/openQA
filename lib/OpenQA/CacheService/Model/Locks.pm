# Copyright (C) 2019 SUSE LLC
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

package OpenQA::CacheService::Model::Locks;
use Mojo::Base -base;

use Mojo::Collection;

has queue => sub { Mojo::Collection->new };

sub enqueued {
    my ($self, $lock) = @_;
    return !!($self->queue->grep(sub { $_ eq $lock })->size == 1);
}

sub dequeue {
    my ($self, $lock) = @_;
    $self->queue($self->queue->grep(sub { $_ ne $lock }));
}

sub enqueue {
    my ($self, $lock) = @_;
    push @{$self->queue}, $lock;
}

1;
