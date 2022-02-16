# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Request::Sync;
use Mojo::Base 'OpenQA::CacheService::Request', -signatures;

# See task OpenQA::Cache::Task::Sync
has [qw(from to)];
has task => 'cache_tests';

sub lock ($self) {
    join('.', map { $self->$_ } qw(from to));
}

sub to_array ($self) { [$self->from, $self->to] }

1;
