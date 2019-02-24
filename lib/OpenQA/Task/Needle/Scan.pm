# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Task::Needle::Scan;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Utils;
use Mojo::URL;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(scan_needles => sub { _needles($app, @_) });
}

sub _needles {
    my ($app, $job, $args) = @_;

    # prevent multiple scan_needles tasks to run in parallel
    return $job->finish('Previous scan_needles job is still active')
      unless my $guard = $app->minion->guard('limit_scan_needles_task', 7200);

    my $dirs = $app->db->resultset('NeedleDirs');

    while (my $dir = $dirs->next) {
        my $needles = $dir->needles;
        while (my $needle = $needles->next) {
            $needle->check_file;
            $needle->update;
        }
    }
    return;
}

1;
