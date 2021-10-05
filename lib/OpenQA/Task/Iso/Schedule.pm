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

package OpenQA::Task::Iso::Schedule;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(schedule_iso => sub { _schedule_iso($app, @_) });
}

sub _schedule_iso {
    my ($app, $minion_job, $args) = @_;

    my $scheduled_product_id = $args->{scheduled_product_id};
    my $scheduling_params    = $args->{scheduling_params};

    my $schema            = $app->schema;
    my $scheduled_product = $schema->resultset('ScheduledProducts')->find($scheduled_product_id);
    if (!$scheduled_product) {
        $minion_job->fail({error => "Scheduled product with ID $scheduled_product_id does not exist."});
    }

    $minion_job->finish($scheduled_product->schedule_iso($scheduling_params));
}

1;
