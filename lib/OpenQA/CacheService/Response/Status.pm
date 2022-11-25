# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Response::Status;
use Mojo::Base 'OpenQA::CacheService::Response', -signatures;

sub is_downloading ($self) { ($self->data->{status} // '') eq 'downloading' }
sub is_processed ($self) { ($self->data->{status} // '') eq 'processed' }
sub output ($self) { $self->has_error ? $self->error : $self->data->{output} }
sub result ($self) { $self->data->{result} }

1;
