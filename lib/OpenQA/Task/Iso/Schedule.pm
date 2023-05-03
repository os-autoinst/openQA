# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Iso::Schedule;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use OpenQA::Utils 'format_tx_error';
use Mojo::URL;
use Mojo::UserAgent;

use constant SCENARIO_DEFS_YAML_MAX_REDIRECTS => $ENV{OPENQA_SCENARIO_DEFINITIONS_YAML_MAX_REDIRECTS} // 2;
use constant SCENARIO_DEFS_YAML_MAX_SIZE => $ENV{OPENQA_SCENARIO_DEFINITIONS_YAML_MAX_SIZE} // (512 * 1024);
use constant SCENARIO_DEFS_YAML_UA_ARGS =>
  (max_redirects => SCENARIO_DEFS_YAML_MAX_REDIRECTS, max_response_size => SCENARIO_DEFS_YAML_MAX_SIZE);

sub register ($self, $app, @) {
    $app->minion->add_task(schedule_iso => sub { _schedule_iso($app, @_) });
}

sub _download_scenario_definitions ($minion_job, $scheduled_product, $scheduling_params) {
    return 1 unless my $file = $scheduling_params->{SCENARIO_DEFINITIONS_YAML_FILE};
    my $url = Mojo::URL->new($file);
    my $scheme = $url->scheme;
    return 1 unless $scheme eq 'http' || $scheme eq 'https';
    return 1 unless $url->host eq 'raw.githubusercontent.com';    # restrict this for now to GitHub
    my $ua = Mojo::UserAgent->new(SCENARIO_DEFS_YAML_UA_ARGS);
    my $tx = $ua->get($url);
    if (my $err = $tx->error) {
        my $msg = format_tx_error($err);
        my $res = {error => "Unable to download SCENARIO_DEFINITIONS_YAML_FILE from '$url': $msg"};
        $scheduled_product->set_done($res);
        $minion_job->finish($res);
        return 0;
    }
    $scheduling_params->{SCENARIO_DEFINITIONS_YAML} = $tx->res->body;
    return 1;
}

sub _schedule_iso ($app, $minion_job, $args, @) {
    my $scheduled_product_id = $args->{scheduled_product_id};
    my $scheduling_params = $args->{scheduling_params};
    return $minion_job->fail({error => "Scheduled product with ID $scheduled_product_id does not exist."})
      unless my $scheduled_product = $app->schema->resultset('ScheduledProducts')->find($scheduled_product_id);
    return undef unless _download_scenario_definitions($minion_job, $scheduled_product, $scheduling_params);
    $minion_job->finish($scheduled_product->schedule_iso($scheduling_params));
}

1;
