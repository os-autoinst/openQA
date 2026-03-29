# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Response;
use Mojo::Base -base, -signatures;

use constant MAX_INACTIVE_JOBS_OFFSET => 40;

has [qw(data error)];

# define soft-limit for inactive Minion jobs (enforced when determining idle worker slots availability)
has max_inactive_jobs => $ENV{OPENQA_CACHE_MAX_INACTIVE_JOBS} // 5;

# define hard-limit for inactive Minion jobs (enforced on setup of already started openQA job)
has max_inactive_jobs_hard_limit => sub ($self) {
    $ENV{OPENQA_CACHE_MAX_INACTIVE_JOBS_HARD_LIMIT} // ($self->max_inactive_jobs + MAX_INACTIVE_JOBS_OFFSET);
};

sub has_error ($self) { !!$self->error }

1;
