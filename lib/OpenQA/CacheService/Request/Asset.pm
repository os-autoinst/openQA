# Copyright 2018-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Request::Asset;
use Mojo::Base 'OpenQA::CacheService::Request', -signatures;

# See task OpenQA::Cache::Task::Asset
has [qw(id type asset host)];
has task => 'cache_asset';

# Generate same lock for asset/host
sub lock ($self) {
    join('.', map { $self->$_ } qw(asset host));
}

sub to_array ($self) { [$self->id, $self->type, $self->asset, $self->host] }

1;
