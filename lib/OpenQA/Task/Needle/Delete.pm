# Copyright 2019 SUSE LLC
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

package OpenQA::Task::Needle::Delete;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Scalar::Util 'looks_like_number';

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(delete_needles => sub { _delete_needles($app, @_) });
}

sub _delete_needles {
    my ($app, $minion_job, $args) = @_;

    # prevent multiple save_needle and delete_needles tasks to run in parallel
    return $minion_job->finish({error => 'Another save or delete needle job is ongoing. Try again later.'})
      unless my $guard = $app->minion->guard('limit_needle_task', 7200);

    my $schema     = $app->schema;
    my $needles    = $schema->resultset('Needles');
    my $user       = $schema->resultset('Users')->find($args->{user_id});
    my $needle_ids = $args->{needle_ids};

    my (@removed_ids, @errors);

    for my $needle_id (@$needle_ids) {
        my $needle = looks_like_number($needle_id) ? $needles->find($needle_id) : undef;
        if (!$needle) {
            push(
                @errors,
                {
                    id      => $needle_id,
                    message => "Unable to find needle with ID \"$needle_id\"",
                });
            next;
        }

        if (my $error = $needle->remove($user)) {
            push(
                @errors,
                {
                    id           => $needle_id,
                    display_name => $needle->filename,
                    message      => $error,
                });
            next;
        }

        push(@removed_ids, $needle_id);
    }

    return $minion_job->finish(
        {
            removed_ids => \@removed_ids,
            errors      => \@errors
        });
}

1;
