# Copyright (C) 2019-2021 SUSE LLC
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
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::CacheService::Plugin::Helpers;
use Mojo::Base 'Mojolicious::Plugin';
use Time::Seconds;

sub register {
    my ($self, $app) = @_;

    # To determine download progress and guard against parallel downloads of the same file
    $app->helper('progress.downloading_job' => \&_progress_downloading_job);
    $app->helper('progress.is_downloading'  => \&_progress_is_downloading);
    $app->helper('progress.guard'           => \&_progress_guard);
}

sub _progress_downloading_job {
    my ($c, $lock) = @_;
    return $c->downloads->find($lock);
}

sub _progress_is_downloading {
    my ($c, $lock) = @_;
    return !$c->minion->lock("cache_$lock", 0);
}

sub _progress_guard {
    my ($c, $lock, $job_id) = @_;
    my $guard = $c->minion->guard("cache_$lock", ONE_DAY);
    $c->downloads->add($lock, $job_id) if $guard;
    return $guard;
}

1;
