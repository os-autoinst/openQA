# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CacheService::Response;
use Mojo::Base -base;

has [qw(data error)];
has max_inactive_jobs => $ENV{OPENQA_CACHE_MAX_INACTIVE_JOBS} // 5;

sub has_error { !!shift->error }

1;
