# Copyright (C) 2015 SUSE Linux GmbH
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

package OpenQA::WebAPI::Controller::API::V1::Job;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;
use OpenQA::IPC;
use OpenQA::Schema::Result::Jobs;
use Try::Tiny;
use DBIx::Class::Timestamps qw/now/;

sub list {
    my $self = shift;

    my %args;
    my @args
      = qw/build iso distri version flavor maxage scope group groupid limit page before after arch hdd_1 test machine/;
    for my $arg (@args) {
        next unless defined(my $value = $self->param($arg));
        $args{$arg} = $value;
    }
    # For these, we accept a single value, a single instance of the arg
    # with a comma-separated list of values, or multiple instances of the
    # arg. In all cases we're going to convert to an array ref of values:
    # we could let query_jobs do the string splitting for us, but this is
    # clearer.
    for my $arg (qw/state ids result/) {
        next unless defined $self->param($arg);
        if (index($self->param($arg), ',') != -1) {
            $args{$arg} = [split(',', $self->param($arg))];
        }
        else {
            $args{$arg} = $self->every_param($arg);
        }
    }

    my $rs = $self->db->resultset('Jobs')->complex_query(%args);
    my @jobarray;
    if (defined $self->param('latest')) {
        @jobarray = $rs->latest_jobs;
    }
    else {
        @jobarray = $rs->all;
    }
    my %jobs = map { $_->id => $_ } @jobarray;

    # we can't prefetch too much at once as the resulting JOIN will kill our performance horribly
    # (not so much the JOIN itself, but parsing the result containing duplicated information)
    # so we fetch some fields in a second step

    # fetch job assets
    for my $job (values %jobs) {
        $job->{_assets} = [];
    }
    my $jas = $self->db->resultset('JobsAssets')->search({job_id => {in => [keys %jobs]}}, {prefetch => ['asset']});
    while (my $ja = $jas->next) {
        my $job = $jobs{$ja->job_id};
        push(@{$job->{_assets}}, $ja->asset);
    }

    # prefetch groups
    my %groups;
    for my $job (values %jobs) {
        next unless $job->group_id;
        $groups{$job->group_id} ||= $job->group;
        $job->group($groups{$job->group_id});
    }

    my $modules = $self->db->resultset('JobModules')->search({job_id => {in => [keys %jobs]}}, {order_by => 'id'});
    while (my $m = $modules->next) {
        my $job = $jobs{$m->job_id};
        $job->{_modules} ||= [];
        push(@{$job->{_modules}}, $m);
    }

    my @results;
    for my $id (sort keys %jobs) {
        my $job = $jobs{$id};
        my $jobhash = $job->to_hash(assets => 1, deps => 1);
        $jobhash->{modules} = [];
        for my $module (@{$job->{_modules}}) {
            my $modulehash = {
                name     => $module->name,
                category => $module->category,
                result   => $module->result,
                flags    => []};
            for my $flag (qw/important fatal milestone/) {
                if ($module->get_column($flag)) {
                    push(@{$modulehash->{flags}}, $flag);
                }
            }
            push(@{$jobhash->{modules}}, $modulehash);
        }
        push @results, $jobhash;
    }
    $self->render(json => {jobs => \@results});
}

sub create {
    my $self   = shift;
    my $params = $self->req->params->to_hash;

    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    # restore URL encoded /
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;

    my $json = {};
    my $status;
    try {
        my $job = $self->db->resultset('Jobs')->create_from_settings(\%params);
        $self->emit_event('openqa_job_create', {id => $job->id, %params});
        $json->{id} = $job->id;

        # enqueue gru job
        $self->db->resultset('GruTasks')->create(
            {
                taskname => 'limit_assets',
                priority => 10,
                args     => [],
                run_at   => now(),
            });

        notify_workers;
    }
    catch {
        $status = 400;
        $json->{error} = "$_";
    };
    $self->render(json => $json, status => $status);
}

sub grab {
    my $self = shift;
    my $ipc  = OpenQA::IPC->ipc;

    my $workerid = $self->stash('workerid');
    my $blocking = int($self->param('blocking') || 0);
    my $workerip = $self->tx->remote_address;
    my $caps     = {};

    $caps->{cpu_modelname} = $self->param('cpu_modelname');
    $caps->{cpu_arch}      = $self->param('cpu_arch');
    $caps->{cpu_opmode}    = $self->param('cpu_opmode');
    $caps->{mem_max}       = $self->param('mem_max');

    my $res = $ipc->scheduler('job_grab',
        {workerid => $workerid, blocking => $blocking, workerip => $workerip, workercaps => $caps});
    $self->emit_event('openqa_job_grab',
        {workerid => $workerid, blocking => $blocking, workerip => $workerip, id => $res->{id}});
    $self->render(json => {job => $res});
}

sub show {
    my $self   = shift;
    my $job_id = int($self->stash('jobid'));
    my $job    = $self->db->resultset("Jobs")->search({'me.id' => $job_id}, {prefetch => 'settings'})->first;
    if ($job) {
        $self->render(json => {job => $job->to_hash(assets => 1, deps => 1)});
    }
    else {
        $self->reply->not_found;
    }
}

# set_waiting and set_running
sub set_command {
    my $self    = shift;
    my $jobid   = int($self->stash('jobid'));
    my $command = 'job_set_' . $self->stash('command');
    my $ipc     = OpenQA::IPC->ipc;

    my $res = try { $ipc->scheduler($command, $jobid) };
    $self->emit_event('openqa_' . $command, {id => $jobid}) if ($res);
    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
    $self->render(json => {result => \$res});
}

sub destroy {
    my $self = shift;

    my $job = $self->app->schema->resultset("Jobs")->find($self->stash('jobid'));
    if (!$job) {
        $self->reply->not_found;
        return;
    }
    $self->emit_event('openqa_job_delete', {id => $job->id});
    $job->delete;
    $self->render(json => {result => 1});
}

sub prio {
    my ($self) = @_;
    my $job    = $self->app->schema->resultset("Jobs")->find($self->stash('jobid'));
    my $res    = $job->set_prio($self->param('prio'));

    # See comment in set_command
    $self->render(json => {result => \$res});
}

# replaced in favor of done
sub result {
    my ($self) = @_;
    my $jobid  = int($self->stash('jobid'));
    my $result = $self->param('result');
    my $ipc    = OpenQA::IPC->ipc;

    my $res = $self->app->schema->resultset("Jobs")->find($jobid)->update({result => $result});
    $self->emit_event('openqa_job_update_result', {id => $jobid, result => $result}) if ($res);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

# this is the general worker update call
sub update_status {
    my ($self) = @_;
    my $jobid  = int($self->stash('jobid'));
    my $status = $self->req->json->{status};
    my $job    = $self->app->schema->resultset("Jobs")->find($jobid);
    my $ret    = $job->update_status($status);

    $self->render(json => $ret);
}

# used by the worker to upload files to the test
sub create_artefact {
    my ($self) = @_;

    my $jobid = int($self->stash('jobid'));
    my $job   = $self->app->schema->resultset("Jobs")->find($jobid);
    if (!$job) {
        $self->reply->not_found;
        return;
    }
    # mark the worker as alive
    if (!$job->worker) {
        log_warning($job->id . " got an artefact but has no worker. huh?");
        $self->reply->not_found;
        return;
    }
    $job->worker->seen;

    if ($self->param('image')) {
        $job->store_image($self->param('file'), $self->param('md5'), $self->param('thumb') // 0);
        $self->render(text => "OK");
        return;
    }
    elsif ($self->param('asset')) {
        my $abs = $job->create_asset($self->param('file'), $self->param('asset'));
        $self->render(json => {temporary => $abs});
        return;
    }
    if ($job->create_artefact($self->param('file'), $self->param('ulog'))) {
        $self->render(text => "OK");
    }
    else {
        $self->render(text => "FAILED");
    }
}

sub ack_temporary {
    my ($self) = @_;

    my $temp = $self->param('temporary');
    if (-f $temp) {
        $self->app->log->debug("ACK $temp");
        if ($temp =~ /^(.*)\.TEMP-[^\/]*$/) {
            my $asset = $1;
            $self->app->log->debug("RENAME $temp to $asset");
            rename($temp, $asset);
        }
    }
    $self->render(text => "OK");
}

sub done {
    my ($self) = @_;

    my $jobid  = int($self->stash('jobid'));
    my $result = $self->param('result');
    my $newbuild;
    $newbuild = 1 if defined $self->param('newbuild');

    my $job = $self->db->resultset('Jobs')->find($jobid);
    if (!$job) {
        $self->reply->not_found;
        return;
    }
    my $res;
    if ($newbuild) {
        $res = $job->done(result => $result, newbuild => $newbuild);
    }
    else {
        $res = $job->done(result => $result);
    }

    # use $res as a result, it is recomputed result by scheduler
    $self->emit_event('openqa_job_done', {id => $jobid, result => $res, newbuild => $newbuild});

    # notify workers if job has any chained children
    my $children = $job->deps_hash->{children};
    if (@{$children->{Chained}} && grep { $res eq $_ } OpenQA::Schema::Result::Jobs::OK_RESULTS) {
        $self->app->log->debug("Job result OK and has chained children! Notifying workers");
        notify_workers;
    }

    # See comment in set_command
    $self->render(json => {result => \$res});
}

# Used for both apiv1_restart and apiv1_restart_jobs
sub restart {
    my ($self) = @_;
    my $jobs = $self->param('jobid');
    if ($jobs) {
        $self->app->log->debug("Restarting job $jobs");
        $jobs = [$jobs];
    }
    else {
        $jobs = $self->every_param('jobs');
        $self->app->log->debug("Restarting jobs @$jobs");
    }

    my $ipc = OpenQA::IPC->ipc;
    my $res = $ipc->scheduler('job_restart', $jobs);
    for (my $i = 0; $i < @$res; $i++) {
        $self->emit_event('openqa_job_restart', {id => $jobs->[$i], result => $res->[$i]});
    }
    my @urls = map { $self->url_for('test', testid => $_) } @$res;
    $self->render(json => {result => $res, test_url => \@urls});
}

# Used for both apiv1_cancel and apiv1_cancel_jobs
sub cancel {
    my ($self) = @_;
    my $jobid = $self->param('jobid');

    my $ipc = OpenQA::IPC->ipc;
    my $res;
    if ($jobid) {
        $self->db->resultset('Jobs')->find($jobid)->cancel;
        $self->emit_event('openqa_job_cancel', {id => int($jobid)});
    }
    else {
        my $params = $self->req->params->to_hash;
        $res = $self->db->resultset('Jobs')->cancel_by_settings($params, 0);
        $self->emit_event('openqa_job_cancel_by_settings', $params) if ($res);
    }

    $self->render(json => {result => $res});
}

sub duplicate {
    my ($self) = @_;

    my $jobid = int($self->param('jobid'));
    my $job   = $self->db->resultset('Jobs')->find($jobid);
    if (!$job) {
        $self->reply->not_found;
        return;
    }
    my $args;
    if (defined $self->param('prio')) {
        $args->{prio} = int($self->param('prio'));
    }
    if (defined $self->param('dup_type_auto')) {
        $args->{dup_type_auto} = 1;
    }

    my $dup = $job->auto_duplicate($args);
    if ($dup) {
        notify_workers;
        $self->emit_event(
            'openqa_job_duplicate',
            {
                id     => $job->id,
                auto   => $args->{dup_type_auto} // 0,
                result => $dup->id
            });
        $self->render(json => {id => $dup->id});
    }
    else {
        $self->render(json => {});
    }
}

sub whoami {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');
    $self->render(json => {id => $jobid});
}

1;
# vim: set sw=4 et:
