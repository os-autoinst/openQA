# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Request::Sync;
use Mojo::Base 'OpenQA::CacheService::Request';

# See task OpenQA::Cache::Task::Sync
has [qw(from to)];
has task => 'cache_tests';

sub lock {
    my $self = shift;
    return join('.', map { $self->$_ } qw(from to));
}

sub to_array {
    my $self = shift;
    return [$self->from, $self->to];
}

1;
