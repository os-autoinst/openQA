# Copyright (C) 2019 SUSE Linux GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Plugin::ObsRsync::Runner;
use strict;
use warnings;
use IPC::System::Simple qw(system $EXITVAL);

sub newRunner {
    my $app = shift;
    $app->minion->add_task(
        obs_rsync => sub {
            my ($job, $args) = @_;
            eval { system([0], "bash", @$args); 1 };
            $app->minion->unlock('obs_rsync_lock');
            $job->finish($EXITVAL);
        });
}

my $lock_timeout = 3600;

sub Run {
    my ($app, $home, $limit, $retry_timeout, $folder) = @_;
    my $minion = $app->minion;
    my @args   = ($home . "/rsync.sh", $folder);

    my $bool = $minion->lock('obs_rsync_lock', $lock_timeout, {limit => $limit});
    if (!$bool) {
        return 1 unless $retry_timeout;
        sleep $retry_timeout;
        $minion->lock('obs_rsync_lock', $lock_timeout, {limit => $limit}) or return 1;
    }
    my $id = $minion->enqueue(obs_rsync => [\@args]);
    return 1 if not $id;
    $minion->job($id)->start();
    return 0;
}

1;
