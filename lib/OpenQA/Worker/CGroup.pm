# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Worker::CGroup;
use Mojo::Base 'Mojo::IOLoop::ReadWriteProcess::CGroup::v2', -signatures;

use Feature::Compat::Try;
use Mojo::Collection 'c';
use OpenQA::Log 'log_warning';

# the cgroup may already be gone when the container cleans up after the job
sub processes ($self) {
    return c() unless -d $self->_cgroup;
    try { return $self->SUPER::processes }
    catch ($e) {
        chomp $e;
        log_warning('Unable to list processes of cgroup ' . $self->_cgroup . ": $e");
        return c();
    }
}

1;
