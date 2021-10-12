# Copyright 2014-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::JobTemplate;
use Mojo::Base 'Mojolicious::Controller';
use Try::Tiny;
use OpenQA::YAML qw(load_yaml dump_yaml);

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::JobTemplate

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::JobTemplate;

=head1 DESCRIPTION

Implements API method for handling job templates in openQA.

=head1 METHODS

=over 4

=item list()

Shows information for the job templates defined in the system. If given a job template id, only the
information for that template is shown, otherwise will attempt to fetch job templates based on any
of the following parameters: machine name or id, test suite name or id, distri, arch, version, flavor,
product id or group id. If none of those arguments are passed to the method, will attempt to list
all job templates defined in the system.

Returns a list of job templates containing the following information for each template: template id,
priority, group name, product (id, arch, distri, flavor, group and version), machine (id and name)
and test suite (id and name).

=back

=cut

sub list {
    my $self = shift;

    my $schema = $self->schema;
    my @templates;
    eval {
        if (my $id = $self->param('job_template_id')) {
            @templates = $schema->resultset("JobTemplates")->search({id => $id});
        }

        else {

            my %cond;
            if (my $value = $self->param('machine_name')) { $cond{'machine.name'} = $value }
            if (my $value = $self->param('test_suite_name')) { $cond{'test_suite.name'} = $value }
            for my $id (qw(arch distri flavor version)) {
                if (my $value = $self->param($id)) { $cond{"product.$id"} = $value }
            }
            for my $id (qw(machine_id test_suite_id product_id group_id)) {
                if (my $value = $self->param($id)) { $cond{$id} = $value }
            }

            my $has_query = grep { $cond{$_} } (
                qw(machine_name machine_id test_suite.name test_suite_id group_id product.arch product.distri),
                qw(product.flavor product.version product_id)
            );

            if ($has_query) {
                my $attrs
                  = {join => ['machine', 'test_suite', 'product'], prefetch => [qw(machine test_suite product)]};
                @templates = $schema->resultset("JobTemplates")->search(\%cond, $attrs);
            }
            else {
                @templates
                  = $schema->resultset("JobTemplates")->search({}, {prefetch => [qw(machine test_suite product)]});
            }
        }
    };

    if (my $error = $@) { return $self->render(json => {error => $error}, status => 404) }

    $self->render(json => {JobTemplates => [map { $_->to_hash } @templates]});
}

=over 4

=item schedules()

Serializes the given job group with relevant test suites by architecture and products (mediums), or all available
groups defined in the system if no group id is specified.
Common defaults for prio and machine are represented in the defaults key.

Returns a YAML template representing the job group(s).

=back

=cut

sub schedules {
    my $self = shift;

    my $single = ($self->param('id') or $self->param('name'));
    my $yaml = $self->_get_job_groups($self->param('id'), $self->param('name'));

    if ($single) {
        # only return the YAML of one group
        $yaml = (values %$yaml)[0];
    }
    my $json_code = sub {
        return $self->render(json => $yaml);
    };
    my $yaml_code = sub {
        # In the case of a single group we return the template directly
        # without encoding it to a string.
        # This is different to the behaviour when JSON is requested.
        # It is deprecated.
        unless ($single) {
            # YAML renderer expects a YAML string
            $yaml = dump_yaml(string => $yaml);
        }
        $self->render(yaml => $yaml);
    };
    $self->respond_to(
        json => $json_code,
        any => $yaml_code,
        yaml => $yaml_code,
    );
}

sub _get_job_groups {
    my ($self, $id, $name) = @_;

    my %yaml;
    my $groups = $self->schema->resultset("JobGroups")->search(
        $id ? {id => $id} : ($name ? {name => $name} : undef),
        {select => [qw(id name parent_id default_priority template)]});
    while (my $group = $groups->next) {
        # Use stored YAML template from the database if available
        $yaml{$group->name} = $group->to_yaml;
    }

    return \%yaml;
}

=over 4

=item update()

Updates a job group according to the given YAML template. Test suites are added or modified
as needed to reflect the difference to what's specified in the template.
The given YAML will be validated and results in an error if it doesn't conform to the schema.

=over 8

=item template

A YAML document describing the job template. The template will be validated against the schema.

=item preview

  preview => 1

Performs a dry-run without committing any changes to the database.

=item expand

  expand => 1

Computes the result of expanding aliases, defaults and settings used in the YAML. This can be
used in tandem with B<preview> to see the effects of hypothetical changes or when saving changes.
Posting the same document unmodified is also a supported use case.

The response will fill in B<result> with the expanded YAML document.

=item reference

  reference => $reference

If specified, this must be a YAML document matching the last known state. If the actual state of the
database changes before the update transaction it's considered an error.
A client can use this to handle editing conflicts between multiple users.

=item schema

  schema => JobTemplates-01.yaml

The schema must be specified to indicate the format of the posted document.

=back

Returns a 400 code on error, or a 303 code and the job template id within a JSON block on success.

The response will have these fields, depending on the options used:

=over

=item B<id>: the ID of the job group

=item B<error>: an array of errors if validation or updating of the YAML document failed

=item B<template>: the YAML document posted as a B<reference> in the original request

=item B<preview>: set to 1 if B<preview> was specified in the original request

=item B<changes>: a diff between the previous and posted YAML document if they mismatch

=item B<result>: the expanded YAML if B<expand> was specified in the original request

=back

Note that an I<openqa_jobtemplate_create> event is emitted with the same fields contained
in the response if any changes to the database were made.

=back

=cut

sub update {
    my $self = shift;

    my $validation = $self->validation;
    # Note: id is a regular param because it's part of the path
    $validation->required('name') unless $self->param('id');
    $validation->required('template');
    $validation->required('schema')->like(qr/^[^.\/]+\.yaml$/);
    $validation->optional('preview')->num(undef, 1);
    $validation->optional('expand')->num(undef, 1);
    $validation->optional('reference');
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $data = {};
    my $errors = [];
    my $yaml = $validation->param('template') // '';
    try {
        $data = load_yaml(string => $validation->param('template'));
        $errors = $self->app->validate_yaml($data, $validation->param('schema'), $self->app->log->level eq 'debug');
    }
    catch {
        # Push the exception to the list of errors without the trailing new line
        push @$errors, substr($_, 0, -1);
    };

    if (@$errors) {
        $self->app->log->error(@$errors);
        $self->respond_to(json => {json => {error => \@$errors}, status => 400},);
        return;
    }

    my $schema = $self->schema;
    my $job_groups = $schema->resultset('JobGroups');
    my $job_templates = $schema->resultset('JobTemplates');
    my $json = {};

    try {
        my $id = $self->param('id');
        my $name = $validation->param('name');
        my $job_group = $job_groups->find($id ? {id => $id} : ($name ? {name => $name} : undef),
            {select => [qw(id name template)]});
        die "Job group " . ($name // $id) . " not found\n" unless $job_group;
        my $group_id = $job_group->id;
        $json->{job_group_id} = $group_id;
        # Backwards compatibility: ID used to mean group ID on this route
        $json->{id} = $group_id;

        if (my $reference = $validation->param('reference')) {
            my $template = $job_group->to_yaml;
            $json->{template} = $template;
            # Compare with no regard for trailing whitespace
            chomp $template;
            chomp $reference;
            die "Template was modified\n" unless $template eq $reference;
        }

        my $job_template_names = $job_group->template_data_from_yaml($data);
        if ($validation->param('expand')) {
            # Preview mode: Get the expected YAML without changing the database
            $json->{result} = $job_group->expand_yaml($job_template_names);
        }

        $schema->txn_do(
            sub {
                my @job_template_ids;
                foreach my $key (sort keys %$job_template_names) {
                    push @job_template_ids,
                      $job_templates->create_or_update_job_template($group_id, $job_template_names->{$key});
                }
                $json->{ids} = \@job_template_ids;

                # Drop entries we haven't touched in add/update loop
                $job_templates->search(
                    {
                        id => {'not in' => \@job_template_ids},
                        group_id => $group_id,
                    })->delete();

                if (my $diff = $job_group->text_diff($yaml)) {
                    $json->{changes} = $diff;
                }

                # Preview mode: Get the expected YAML and rollback the result
                if ($validation->param('preview')) {
                    $json->{preview} = int($validation->param('preview'));
                    $self->schema->txn_rollback;
                }
                else {
                    # Store the original YAML template after all changes have been made
                    $job_group->update({template => $yaml});
                }
            });
    }
    catch {
        # Push the exception to the list of errors without the trailing new line
        push @$errors, substr($_, 0, -1);
    };

    if (@$errors) {
        $json->{error} = \@$errors;
        $self->app->log->error(@$errors);
        $self->respond_to(json => {json => $json, status => 400},);
        return;
    }

    $self->emit_event('openqa_jobtemplate_create', $json) unless $validation->param('preview');
    $self->respond_to(json => {json => $json});
}

=over 4

=item create()

Creates a new job template. If the method receives a valid product id as argument, it will
also check for the following arguments: machine id, group id, test suite id and priority. If
no valid product id is received as argument, the method will instead check for the following
arguments: product name, machine name, test suite name, arch, distri, flavor, version and
priority. Returns a 400 code on error, or a 303 code and the job template id within a JSON
block on success.

=back

=cut

sub create {
    my $self = shift;

    my $error;
    my @ids;

    my $validation = $self->validation;
    my $has_product_id = $validation->optional('product_id')->num(0)->is_valid;

    # validate/read priority
    my $prio_regex = qr/^(inherit|[0-9]+)\z/;
    if ($has_product_id) {
        $validation->optional('prio')->like($prio_regex);
    }
    else {
        $validation->required('prio')->like($prio_regex);
    }
    $validation->optional('prio_only')->num(1);
    my $prio = $validation->param('prio');
    $prio = ((!$prio || $prio eq 'inherit') ? undef : $prio);

    my $schema = $self->schema;
    my $group_id = $self->param('group_id');
    my $group = $schema->resultset("JobGroups")->find({id => $group_id});

    if ($group && $group->template) {
        # An existing group with a YAML template must not be updated manually
        $error = 'Group "' . $group->name . '" must be updated through the YAML template';
    }
    elsif ($has_product_id) {
        for my $param (qw(machine_id group_id test_suite_id)) {
            $validation->required($param)->num(0);
        }
        return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

        my $values = {
            prio => $prio,
            product_id => $validation->param('product_id'),
            machine_id => $validation->param('machine_id'),
            group_id => $group_id,
            test_suite_id => $validation->param('test_suite_id')};
        eval { push @ids, $schema->resultset("JobTemplates")->create($values)->id };
        $error = $@;
    }
    elsif ($validation->param('prio_only')) {
        for my $param (qw(group_id test_suite_id)) {
            $validation->required($param)->num(0);
        }
        return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

        eval {
            my $job_templates = $schema->resultset("JobTemplates")->search(
                {
                    group_id => $group_id,
                    test_suite_id => $validation->param('test_suite_id'),
                });
            push @ids, $_->id for $job_templates->all;
            $job_templates->update(
                {
                    prio => $prio,
                });
        };
        $error = $@;
    }
    else {
        for my $param (qw(group_name machine_name test_suite_name arch distri flavor version)) {
            $validation->required($param);
        }
        return $self->reply->validation_error({format => 'json'}) if $validation->has_error;
        my $values = {
            product => {
                arch => $validation->param('arch'),
                distri => $validation->param('distri'),
                flavor => $validation->param('flavor'),
                version => $validation->param('version')
            },
            group => {name => $validation->param('group_name')},
            machine => {name => $validation->param('machine_name')},
            prio => $prio,
            test_suite => {name => $validation->param('test_suite_name')}};
        eval { push @ids, $schema->resultset("JobTemplates")->create($values)->id };
        $error = $@;
    }

    my $status;
    my $json = {ids => \@ids};
    $json->{job_group_id} = $group_id if $group_id;
    # Backwards compatibility: ID for a single job template
    $json->{id} = $ids[0] if scalar @ids == 1;

    if ($error) {
        $self->app->log->error($error);
        $json->{error} = $error;
        $status = 400;
    }
    else {
        $self->emit_event(openqa_jobtemplate_create => $json);
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
        });
}

=over 4

=item destroy()

Deletes a job template given its id. Returns a 404 error code if the template is not found,
a 400 code on other errors or a 303 code on success.

=back

=cut

sub destroy {
    my $self = shift;
    my $job_templates = $self->schema->resultset('JobTemplates');

    my $status;
    my $error;
    my $json = {};

    my $job_template = $job_templates->find({id => $self->param('job_template_id')});
    if ($job_template && $job_template->group->template) {
        # A test suite that is part of a group with a YAML template must not be deleted manually
        $error = 'Test suites in group "' . $job_template->group->name . '" must be updated through the YAML template';
        $status = 400;
    }
    elsif ($job_template) {
        my $rs;
        eval { $rs = $job_template->delete };
        $error = $@;

        if ($rs) {
            $json->{result} = int($rs);
            $self->emit_event('openqa_jobtemplate_delete', {id => $self->param('job_template_id')});
        }
        else {
            $status = 400;
        }
    }
    else {
        $status = 404;
        $error = 'Not found';
    }

    if ($error) {
        $self->app->log->error($error);
        $json->{error} = $error;
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
        });
}

1;
