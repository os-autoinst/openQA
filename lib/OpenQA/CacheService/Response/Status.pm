# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Response::Status;
use Mojo::Base 'OpenQA::CacheService::Response';

sub is_downloading { (shift->data->{status} // '') eq 'downloading' }
sub is_processed { (shift->data->{status} // '') eq 'processed' }

sub output {
    my $self = shift;
    return $self->has_error ? $self->error : $self->data->{output};
}

sub result { shift->data->{result} }

1;
