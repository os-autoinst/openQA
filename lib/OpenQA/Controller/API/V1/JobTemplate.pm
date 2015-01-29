# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Controller::API::V1::JobTemplate;
use Mojo::Base 'Mojolicious::Controller';

sub list {
    my $self = shift;

    my @templates;
    eval {
        if ($self->param("job_template_id")) {
            @templates = $self->db->resultset("JobTemplates")->search({id => $self->param("job_template_id")});
        }
        elsif ($self->param('machine_name')
            ||$self->param('machine_id')
            ||$self->param('test_suite_name')
            ||$self->param('test_suite_id')
            ||$self->param('arch') && $self->param('distri') && $self->param('flavor') && $self->param('version')
            ||$self->param('product_id'))
        {

            my %params;

            $params{'machine.name'} = $self->param('machine_name') if $self->param('machine_name');
            $params{'test_suite.name'} = $self->param('test_suite_name') if $self->param('test_suite_name');
            $params{'product.arch'} = $self->param('arch') if $self->param('arch');
            $params{'product.distri'} = $self->param('distri') if $self->param('distri');
            $params{'product.flavor'} = $self->param('flavor') if $self->param('flavor');
            $params{'product.version'} = $self->param('version') if $self->param('version');
            $params{'machine_id'} = $self->param('machine_id') if $self->param('machine_id');
            $params{'test_suite_id'} = $self->param('test_suite_id') if $self->param('test_suite_id');
            $params{'product_id'} = $self->param('product_id') if $self->param('product_id');

            @templates = $self->db->resultset("JobTemplates")->search(\%params, { join => ['machine', 'test_suite', 'product'] });
        }
        else {
            @templates = $self->db->resultset("JobTemplates")->all;
        }
    };
    my $error = $@;

    if ($error) {
        $self->render(json => {error => $error}, status => 404);
        return;
    }

    $self->render(json => {JobTemplates => [map { { id => $_->id,product => {id => $_->product_id,arch => $_->product->arch,distri => $_->product->distri,flavor => $_->product->flavor,version => $_->product->version},machine => {id => $_->machine_id, name => $_->machine->name},test_suite => {id => $_->test_suite_id, name => $_->test_suite->name}} } @templates]});
}

sub create {
    my $self = shift;
    my $error;
    my $id;
    my $validation = $self->validation;

    if ($validation->optional('product_id')->like(qr/^[0-9]+$/)->is_valid) {
        $validation->required('machine_id')->like(qr/^[0-9]+$/);
        $validation->required('test_suite_id')->like(qr/^[0-9]+$/);

        if ($validation->has_error) {
            $error = "wrong parameter: ";
            for my $k (qw/product_id machine_id test_suite_id/) {
                $error .= $k if $validation->has_error($k);
            }
        }
        else {
            eval { $id = $self->db->resultset("JobTemplates")->create({product_id => $self->param('product_id'), machine_id => $self->param('machine_id'),test_suite_id => $self->param('test_suite_id')})->id};
            $error = $@;
        }
    }
    else {
        $validation->required('machine_name');
        $validation->required('test_suite_name');
        $validation->required('arch');
        $validation->required('distri');
        $validation->required('flavor');
        $validation->required('version');

        if ($validation->has_error) {
            $error = "wrong parameter: ";
            for my $k (qw/machine_name test_suite_name arch distri flavor version/) {
                $error .= $k if $validation->has_error($k);
            }
        }
        else {
            eval { $id = $self->db->resultset("JobTemplates")->create({product =>{arch => $self->param('arch'),distri => $self->param('distri'),flavor => $self->param('flavor'),version => $self->param('version')},machine => {name => $self->param('machine_name')},test_suite => {name => $self->param('test_suite_name')},})->id};
            $error = $@;
        }
    }

    my $status;
    my $json = {};

    if ($error) {
        $json->{error} = $error;
        $status = 400;
    }
    else {
        $json->{id} = $id;
    }

    $self->respond_to(
        json => {json => $json, status => $status},
        html => sub {
            if ($error) {
                $self->flash('error', "Error adding the job template: $error");
            }
            else {
                $self->flash(info => 'Job template added');
            }
            $self->res->code(303);
            $self->redirect_to($self->req->headers->referrer);
        }
    );
}

sub destroy {
    my $self = shift;
    my $job_templates = $self->db->resultset('JobTemplates');

    my $status;
    my $json = {};

    my $rs;
    eval {$rs = $job_templates->search({id => $self->param('job_template_id')})->delete };
    my $error = $@;

    if ($rs) {
        if ($rs == 0) {
            $status = 404;
            $error = 'Not found';
        }
        else {
            $json->{result} = int($rs);
        }
    }
    else {
        $json->{error} = $error;
        $status = 400;
    }
    $self->respond_to(
        json => {json => $json, status => $status},
        html => sub {
            if ($error) {
                $self->flash('error', "Error deleting the job template: $error");
            }
            else {
                $self->flash(info => 'Job template deleted');
            }
            $self->res->code(303);
            $self->redirect_to($self->req->headers->referrer);
        }
    );
}

1;
