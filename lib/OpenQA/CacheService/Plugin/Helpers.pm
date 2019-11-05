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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::CacheService::Plugin::Helpers;
use Mojo::Base 'Mojolicious::Plugin';

sub register {
    my ($self, $app) = @_;

    $app->helper(gen_guard_name => sub { join('.', shift->app->session_token, shift) });

    # To determine which jobs are still waiting to be processed
    $app->helper('waiting.enqueued' => \&_waiting_enqueued);
    $app->helper('waiting.dequeue'  => \&_waiting_dequeue);
    $app->helper('waiting.enqueue'  => \&_waiting_enqueue);
}

sub _waiting_enqueued {
    my ($c, $lock) = @_;
    return !$c->minion->lock("wait_locks_$lock", 0);
}

sub _waiting_dequeue {
    my ($c, $lock) = @_;
    $c->minion->unlock("wait_locks_$lock");
}

sub _waiting_enqueue {
    my ($c, $lock) = @_;
    $c->minion->lock("wait_locks_$lock", 432000);
}

1;
