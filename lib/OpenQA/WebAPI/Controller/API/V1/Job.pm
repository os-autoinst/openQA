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
    for my $arg (qw/state build iso distri version flavor maxage scope group limit/) {
        next unless defined $self->param($arg);
        $args{$arg} = $self->param($arg);
    }

    # TODO: convert to DBus call or move query_jobs helper to WebAPI
    my $jobs = OpenQA::Scheduler::Scheduler::query_jobs(%args);
    my @results;
    while (my $job = $jobs->next) {
        my $jobhash = $job->to_hash(assets => 1, deps => 1);
        $jobhash->{modules} = [];
        for my $module ($job->modules) {
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

    my $json = {};
    my $status;
    try {
        my $job = $ipc->scheduler('job_create', \%up_params, 0);
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
    # Referencing the scalar will result in true or false
    # (see http://mojolicio.us/perldoc/Mojo/JSON)
    $self->render(json => {result => \$res});
}

sub destroy {
    my $self = shift;
    my $ipc  = OpenQA::IPC->ipc;
    my $res  = $ipc->scheduler('job_delete', int($self->stash('jobid')));
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
    # See comment in set_command
    $self->render(json => {result => \$res});
}

# this is the general worker update call
sub update_status {
    my ($self) = @_;
    my $jobid  = int($self->stash('jobid'));
    my $status = $self->req->json->{'status'};
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

    my $jobid    = int($self->stash('jobid'));
    my $result   = $self->param('result');
    my $newbuild = 1 if defined $self->param('newbuild');

    my $ipc = OpenQA::IPC->ipc;
    my $res;
    if ($newbuild) {
        $res = $ipc->scheduler('job_set_done', {jobid => $jobid, result => $result, newbuild => $newbuild});
    }
    else {
        $res = $ipc->scheduler('job_set_done', {jobid => $jobid, result => $result});
    }
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

    my $ipc  = OpenQA::IPC->ipc;
    my $res  = $ipc->scheduler('job_restart', $jobs);
    my @urls = map { $self->url_for('test', testid => $_) } @$res;
    $self->render(json => {result => $res, test_url => \@urls});
}

sub cancel {
    my $self = shift;
    my $name = $self->param('name');

    my $ipc = OpenQA::IPC->ipc;
    my $res = $ipc->scheduler('job_cancel', $name, 0);
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
    $self->render(json => {id => $id});
}

sub whoami {
    my ($self) = @_;
    my $jobid = $self->stash('job_id');
    $self->render(json => {id => $jobid});
}

1;
# vim: set sw=4 et:
