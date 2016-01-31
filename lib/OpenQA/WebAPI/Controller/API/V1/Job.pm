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
use Try::Tiny;

sub list {
    my $self = shift;

    my %args;
    for my $arg (qw/build iso distri version flavor maxage scope group groupid limit arch/) {
        next unless defined $self->param($arg);
        $args{$arg} = $self->param($arg);
    }
    # For these, we accept a single value, a single instance of the arg
    # with a comma-separated list of values, or multiple instances of the
    # arg. In all cases we're going to convert to an array ref of values:
    # we could let query_jobs do the string splitting for us, but this is
    # clearer.
    for my $arg (qw/state ids/) {
        next unless defined $self->param($arg);
        if (index($self->param($arg), ',') != -1) {
            $args{$arg} = [split(',', $self->param($arg))];
        }
        else {
            $args{$arg} = $self->every_param($arg);
        }
    }

    # TODO: convert to DBus call or move query_jobs helper to WebAPI
    my @jobarray;
    if (defined $self->param('latest')) {
        @jobarray = OpenQA::Scheduler::Scheduler::query_jobs(%args)->latest_jobs;
    }
    else {
        @jobarray = OpenQA::Scheduler::Scheduler::query_jobs(%args)->all;
    }
    my %jobs = map { $_->id => $_ } @jobarray;

    # we can't prefetch too much at once as the resulting JOIN will kill our performance horribly
    # (not so much the JOIN itself, but parsing the result containing duplicated information)
    # so we fetch some fields in a second step

    # fetch job assets
    my $jas = $self->app->db->resultset('JobsAssets')->search({job_id => {in => [keys %jobs]}}, {prefetch => ['asset']});
    while (my $ja = $jas->next) {
        my $job = $jobs{$ja->job_id};
        $job->{_assets} ||= [];
        push(@{$job->{_assets}}, $ja->asset);
    }

    # prefetch groups
    my %groups;
    for my $job (values %jobs) {
        next unless $job->group_id;
        $groups{$job->group_id} ||= $job->group;
        $job->group($groups{$job->group_id});
    }

    my $modules = $self->app->db->resultset('JobModules')->search({job_id => {in => [keys %jobs]}}, {order_by => 'id'});
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
            for my $flag (qw/important fatal milestone soft_failure/) {
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
    my $ipc    = OpenQA::IPC->ipc;

    # job_create expects upper case keys
    my %up_params = map { uc $_ => $params->{$_} } keys %$params;
    # restore URL encoded /
    my %params = map { $_ => $up_params{$_} =~ s@%2F@/@gr } keys %up_params;

    my $json = {};
    my $status;
    try {
        my $job = $ipc->scheduler('job_create', \%params, 0);
        $self->emit_event('openqa_job_create', {id => $job->{id}, %params});
        $json->{id} = $job->{id};
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

    my $res = $ipc->scheduler('job_grab', {workerid => $workerid, blocking => $blocking, workerip => $workerip, workercaps => $caps});
    $self->emit_event('openqa_job_grab', {workerid => $workerid, blocking => $blocking, workerip => $workerip, id => $res->{id}});
    $self->render(json => {job => $res});
}

sub show {
    my $self = shift;
    my $ipc  = OpenQA::IPC->ipc;

    my $res = $ipc->scheduler('job_get', int($self->stash('jobid')));
    if ($res) {
        $self->render(json => {job => $res});
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
    my $ipc  = OpenQA::IPC->ipc;

    my $res = $ipc->scheduler('job_delete', int($self->stash('jobid')));
    $self->emit_event('openqa_job_delete', {id => $self->stash('jobid')}) if ($res);
    # See comment in set_command
    $self->render(json => {result => \$res});
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

    my $res = $ipc->scheduler('job_update_result', {jobid => $jobid, result => $result});
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
    $self->reply->not_found unless $job;

    if ($self->param('image')) {
        $job->store_image($self->param('file'), $self->param('md5'), $self->param('thumb') // 0);
        $self->render(text => "OK");
        return;
    }
    elsif ($self->param('asset')) {
        $job->create_asset($self->param('file'), $self->param('asset'));
        $self->render(text => "OK");
        return;
    }
    if ($job->create_artefact($self->param('file'), $self->param('ulog'))) {
        $self->render(text => "OK");
    }
    else {
        $self->render(text => "FAILED");
    }
}

sub done {
    my ($self) = @_;

    my $jobid  = int($self->stash('jobid'));
    my $result = $self->param('result');
    my $newbuild;
    $newbuild = 1 if defined $self->param('newbuild');


    my $ipc = OpenQA::IPC->ipc;
    my $res;
    if ($newbuild) {
        $res = $ipc->scheduler('job_set_done', {jobid => $jobid, result => $result, newbuild => $newbuild});
    }
    else {
        $res = $ipc->scheduler('job_set_done', {jobid => $jobid, result => $result});
    }
    $self->emit_event('openqa_job_done', {id => $jobid, result => $result, newbuild => $newbuild}) if ($res);
    # See comment in set_command
    $self->render(json => {result => \$res});
}

# Used for both apiv1_restart and apiv1_restart_jobs
sub restart {
    my ($self) = @_;
    my $jobs = $self->param('name');
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
    if (@$res > 1) {
        $self->emit_event('openqa_jobs_restart', {ids => $jobs, results => $res});
    }
    elsif (@$res == 1) {
        $self->emit_event('openqa_job_restart', {id => $jobs->[0], result => $res->[0]});
    }
    my @urls = map { $self->url_for('test', testid => $_) } @$res;
    $self->render(json => {result => $res, test_url => \@urls});
}

sub cancel {
    my $self = shift;
    my $name = $self->param('name');

    my $ipc = OpenQA::IPC->ipc;
    my $res = $ipc->scheduler('job_cancel', $name, 0);
    $self->emit_event('openqa_job_cancel', {id => $name}) if ($res);
    $self->render(json => {result => $res});
}

sub duplicate {
    my $self  = shift;
    my $jobid = int($self->param('name'));
    my %args  = (jobid => $jobid);
    if (defined $self->param('prio')) {
        $args{prio} = int($self->param('prio'));
    }
    if (defined $self->param('dup_type_auto')) {
        $args{dup_type_auto} = 1;
    }

    my $ipc = OpenQA::IPC->ipc;
    my $id = $ipc->scheduler('job_duplicate', \%args);
    $self->emit_event('openqa_job_duplicate', {id => $jobid, auto => $args{dup_type_auto}, result => $id}) if ($id);
    $self->render(json => {id => $id});
}

sub whoami {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');
    $self->render(json => {id => $jobid});
}

1;
# vim: set sw=4 et:
