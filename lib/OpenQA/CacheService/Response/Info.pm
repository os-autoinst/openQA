# Copyright 2019-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Response::Info;
use Mojo::Base 'OpenQA::CacheService::Response', -signatures;

sub available { !shift->has_error }

sub available_workers ($self) {
    return undef unless $self->available;
    return undef unless my $data = $self->data;
    return $data->{active_workers} != 0 || $data->{inactive_workers} != 0;
}

sub inactive_jobs_exceeded ($self) {
    return undef if $self->max_inactive_jobs < 0;
    return undef unless my $data = $self->data;
    return undef unless $data->{inactive_jobs};
    return $data->{inactive_jobs} > $self->max_inactive_jobs;
}

sub availability_error ($self) {
    return $self->error if $self->has_error;
    return 'No workers active in the cache service' unless $self->available_workers;
    return 'Cache service queue already full (' . $self->max_inactive_jobs . ')' if $self->inactive_jobs_exceeded;
    return undef;
}

1;
