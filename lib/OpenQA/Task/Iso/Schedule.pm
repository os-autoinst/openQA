# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

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
    my $scheduling_params = $args->{scheduling_params};

    my $schema = $app->schema;
    my $scheduled_product = $schema->resultset('ScheduledProducts')->find($scheduled_product_id);
    if (!$scheduled_product) {
        $minion_job->fail({error => "Scheduled product with ID $scheduled_product_id does not exist."});
    }

    $minion_job->finish($scheduled_product->schedule_iso($scheduling_params));
}

1;
