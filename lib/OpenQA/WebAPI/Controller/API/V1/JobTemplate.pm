# Copyright (C) 2014-2019 SUSE Linux Products GmbH
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

package OpenQA::WebAPI::Controller::API::V1::JobTemplate;
use Mojo::Base 'Mojolicious::Controller';
use Try::Tiny;
use JSON::Validator;
use Text::Diff;
use Storable 'dclone';

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
            if (my $value = $self->param('machine_name'))    { $cond{'machine.name'}    = $value }
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

    my $yaml = $self->get_job_groups($self->param('id'), $self->param('name'));

    # Re-indent with group names at the toplevel in case of multiple groups
    if (keys %$yaml > 1) {
        foreach my $group (keys %$yaml) {
            $yaml->{$group} = "'$group': |\n" . ($yaml->{$group} =~ s/^(.+)/  $1/mgr);
        }
    }
    $self->render(yaml => join("\n", map { $yaml->{$_} } sort keys %$yaml));
}

sub get_job_groups {
    my ($self, $id, $name) = @_;

    my %yaml;
    my $groups = $self->schema->resultset("JobGroups")->search(
        $id ? {id => $id} : ($name ? {name => $name} : undef),
        {select => [qw(id name parent_id default_priority template)]});
    while (my $group = $groups->next) {
        my %group;
        # Use stored YAML template from the database if available
        if ($group->template) {
            $yaml{$group->name} = $group->template;
            next;
        }

        # Compile a YAML template from the current state
        my $templates
          = $self->schema->resultset("JobTemplates")
          ->search({group_id => $group->id}, {order_by => 'me.test_suite_id'});

        # Always set the hash of test suites to account for empty groups
        $group{scenarios} = {};
        $group{products}  = {};

        my %machines;
        my %test_suites;
        # Extract products and tests per architecture
        while (my $template = $templates->next) {
            $group{products}{$template->product->name} = {
                distri  => $template->product->distri,
                flavor  => $template->product->flavor,
                version => $template->product->version
            };

            my %test_suite;

            $test_suite{machine} = $template->machine->name;
            $machines{$template->product->arch}{$template->machine->name}++;
            if ($template->prio && $template->prio != $group->default_priority) {
                $test_suite{priority} = $template->prio;
            }

            my $settings = $template->settings_hash;
            $test_suite{settings} = $settings if %$settings;

            my $scenarios = $group{scenarios}{$template->product->arch}{$template->product->name};
            push @$scenarios, {$template->test_suite->name => \%test_suite};
            $group{scenarios}{$template->product->arch}{$template->product->name} = $scenarios;
            $test_suites{$template->product->arch}{$template->test_suite->name}++;
        }

        # Split off defaults
        foreach my $arch (sort keys %{$group{scenarios}}) {
            $group{defaults}{$arch}{priority} = $group->default_priority;
            my $default_machine
              = (sort { $machines{$arch}->{$b} <=> $machines{$arch}->{$a} or $b cmp $a } keys %{$machines{$arch}})[0];
            $group{defaults}{$arch}{machine} = $default_machine;

            foreach my $product (sort keys %{$group{scenarios}->{$arch}}) {
                my @scenarios;
                foreach my $test_suite (@{$group{scenarios}->{$arch}->{$product}}) {
                    foreach my $name (sort keys %$test_suite) {
                        my $attr = $test_suite->{$name};
                        if ($attr->{machine} eq $default_machine) {
                            delete $attr->{machine} if $test_suites{$arch}{$name} == 1;
                        }
                        if (%$attr) {
                            $test_suite->{$name} = $attr;
                            push @scenarios, $test_suite;
                        }
                        else {
                            push @scenarios, $name;
                        }
                    }
                }
                $group{scenarios}{$arch}{$product} = \@scenarios;
            }
        }

        # Note: Stripping the initial document start marker "---"
        $yaml{$group->name} = YAML::XS::Dump(\%group) =~ s/^---\n//r;
    }

    return \%yaml;
}

sub create_or_update_job_template {
    my ($self, $group_id, $args) = @_;

    my $schema                = $self->schema;
    my $machines              = $schema->resultset('Machines');
    my $test_suites           = $schema->resultset('TestSuites');
    my $products              = $schema->resultset('Products');
    my $job_templates         = $schema->resultset('JobTemplates');
    my $job_template_settings = $schema->resultset('JobTemplateSettings');

    die "Machine is empty and there is no default for architecture $args->{arch}\n"
      unless $args->{machine_name};

    # Find machine, product and testsuite
    my $machine = $machines->find({name => $args->{machine_name}});
    die "Machine '$args->{machine_name}' is invalid\n" unless $machine;
    my $product = $products->find(
        {
            arch    => $args->{arch},
            distri  => $args->{product_spec}->{distri},
            flavor  => $args->{product_spec}->{flavor},
            version => $args->{product_spec}->{version},
        });
    die "Product '$args->{product_name}' is invalid\n" unless $product;
    my $test_suite = $test_suites->find({name => $args->{testsuite_name}});
    die "Testsuite '$args->{testsuite_name}' is invalid\n" unless $test_suite;

    # Create/update job template
    my $job_template = $job_templates->find_or_create(
        {
            group_id      => $group_id,
            product_id    => $product->id,
            machine_id    => $machine->id,
            name          => $args->{job_template_name} // "",
            test_suite_id => $test_suite->id,
        },
        {
            key => 'scenario',
        });
    die "Job template name '"
      . ($args->{job_template_name} // $args->{testsuite_name})
      . "' with $args->{product_name} and $args->{machine_name} is already used in job group '"
      . $job_template->group->name . "'\n"
      if $job_template->group_id != $group_id;
    my $job_template_id = $job_template->id;
    $job_template->update({prio => $args->{prio}}) if (defined $args->{prio});

    # Add/update/remove parameter
    my @setting_ids;
    if ($args->{settings}) {
        foreach my $key (sort keys %{$args->{settings}}) {
            my $setting = $job_template_settings->find(
                {
                    job_template_id => $job_template_id,
                    key             => $key,
                });
            if ($setting) {
                $setting->update({value => $args->{settings}->{$key}});
            }
            else {
                $setting = $job_template_settings->find_or_create(
                    {
                        job_template_id => $job_template_id,
                        key             => $key,
                        value           => $args->{settings}->{$key},
                    });
            }
            push(@setting_ids, $setting->id);
        }
    }
    $job_template_settings->search(
        {
            id              => {'not in' => \@setting_ids},
            job_template_id => $job_template_id,
        })->delete();

    return $job_template->id;
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

    my $yaml   = {};
    my $errors = [];
    try {
        # No objects (aka SafeYAML)
        $YAML::XS::LoadBlessed = 0;
        $yaml                  = YAML::XS::Load($self->param('template'));
        $errors = $self->app->validate_yaml($yaml, $self->param('schema'), $self->app->log->level eq 'debug');
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

    my $schema        = $self->schema;
    my $job_groups    = $schema->resultset('JobGroups');
    my $job_templates = $schema->resultset('JobTemplates');
    my $json          = {};

    try {
        my $id        = $self->param('id');
        my $name      = $self->param('name');
        my $job_group = $job_groups->find($id ? {id => $id} : ($name ? {name => $name} : undef),
            {select => [qw(id name template)]});
        die "Job group " . ($name // $id) . " not found\n" unless $job_group;
        my $group_id = $job_group->id;
        $json->{id} = $group_id;

        if ($self->param('reference')) {
            my $reference = $self->get_job_groups($group_id)->{$job_group->name};
            $json->{template} = $reference;
            die "Template was modified\n" unless $reference eq $self->param('reference');
        }

        my $job_template_names = _create_job_templates_from_yaml($yaml);
        if ($self->param('expand')) {
            # Preview mode: Get the expected YAML without changing the database
            my $result = {};
            foreach my $job_template_key (sort keys %$job_template_names) {
                my $spec     = $job_template_names->{$job_template_key};
                my $scenario = {
                    $spec->{job_template_name} // $spec->{testsuite_name} => {
                        machine  => $spec->{machine_name},
                        priority => $spec->{prio},
                        settings => $spec->{settings},
                    }};
                push @{$result->{scenarios}->{$spec->{arch}}->{$spec->{product_name}}}, {%$scenario,};
                $result->{products}->{$spec->{product_name}} = $spec->{product_spec};
            }
            # Note: Stripping the initial document start marker "---"
            $json->{result} = YAML::XS::Dump($result) =~ s/^---\n//r;
        }

        $schema->txn_do(
            sub {
                my @job_template_ids;
                foreach my $job_template_key (sort keys %$job_template_names) {
                    push @job_template_ids,
                      $self->create_or_update_job_template($group_id, $job_template_names->{$job_template_key});
                }

                # Drop entries we haven't touched in add/update loop
                $job_templates->search(
                    {
                        id       => {'not in' => \@job_template_ids},
                        group_id => $group_id,
                    })->delete();

                if ($job_group->template && $job_group->template ne $self->param('template')) {
                    $json->{changes} = "\n" . diff \$job_group->template, \$self->param('template');
                    # Remove the warning about new lines. We don't require that!
                    $json->{changes} =~ s/\\ No newline at end of file\n//;
                    # Remove leading and trailing whitespace
                    $json->{changes} =~ s/^\s+|\s+$//g;
                }

                # Preview mode: Get the expected YAML and rollback the result
                if ($self->param('preview')) {
                    $json->{preview} = int($self->param('preview'));
                    $self->schema->txn_rollback;
                }
                else {
                    # Store the original YAML template after all changes have been made
                    $job_group->update({template => $self->param('template')});
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

    $self->emit_event('openqa_jobtemplate_create', $json) unless $self->param('preview');
    $self->respond_to(json => {json => $json});
}

sub _create_job_templates_from_yaml {
    my ($yaml) = @_;
    my %job_template_names;

    # Add/update job templates from YAML data
    # (create test suites if not already present, fail if referenced machine and product is missing)
    my $yaml_archs    = $yaml->{scenarios};
    my $yaml_products = $yaml->{products};
    my $yaml_defaults = $yaml->{defaults};
    foreach my $arch (sort keys %$yaml_archs) {
        my $yaml_products_for_arch = $yaml_archs->{$arch};
        my $yaml_defaults_for_arch = $yaml_defaults->{$arch};
        foreach my $product_name (sort keys %$yaml_products_for_arch) {
            foreach my $spec (@{$yaml_products_for_arch->{$product_name}}) {
                # Get testsuite, machine, prio and job template settings from YAML data
                my $testsuite_name;
                my $job_template_name;
                # Assign defaults
                my $prio          = $yaml_defaults_for_arch->{priority};
                my $machine_names = $yaml_defaults_for_arch->{machine};
                my $settings      = dclone($yaml_defaults_for_arch->{settings} // {});
                if (ref $spec eq 'HASH') {
                    # We only have one key. Asserted by schema
                    $testsuite_name = (keys %$spec)[0];
                    my $attr = $spec->{$testsuite_name};
                    if ($attr->{priority}) {
                        $prio = $attr->{priority};
                    }
                    if ($attr->{machine}) {
                        $machine_names = $attr->{machine};
                    }
                    if ($attr->{testsuite}) {
                        $job_template_name = $testsuite_name;
                        $testsuite_name    = $attr->{testsuite};
                    }
                    if ($attr->{settings}) {
                        %$settings = (%{$settings // {}}, %{$attr->{settings}});
                    }
                }
                else {
                    $testsuite_name = $spec;
                }

                $machine_names = [$machine_names] if ref($machine_names) ne 'ARRAY';
                foreach my $machine_name (@{$machine_names}) {
                    my $job_template_key
                      = $arch . $product_name . $machine_name . $testsuite_name . ($job_template_name // '');
                    die "Job template name '"
                      . ($job_template_name // $testsuite_name)
                      . "' is defined more than once. "
                      . "Use a unique name and specify 'testsuite' to re-use test suites in multiple scenarios.\n"
                      if $job_template_names{$job_template_key};
                    $job_template_names{$job_template_key} = {
                        prio              => $prio,
                        machine_name      => $machine_name,
                        arch              => $arch,
                        product_name      => $product_name,
                        product_spec      => $yaml_products->{$product_name},
                        job_template_name => $job_template_name,
                        testsuite_name    => $testsuite_name,
                        settings          => $settings
                    };
                }
            }
        }
    }

    return \%job_template_names;
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
    my $id;
    my $affected_rows;

    my $validation      = $self->validation;
    my $is_number_regex = qr/^[0-9]+$/;
    my $has_product_id  = $validation->optional('product_id')->like($is_number_regex)->is_valid;

    # validate/read priority
    my $prio_regex = qr/^(inherit|[0-9]+)$/;
    if ($has_product_id) {
        $validation->optional('prio')->like($prio_regex);
    }
    else {
        $validation->required('prio')->like($prio_regex);
    }
    my $prio = $self->param('prio');
    $prio = ((!$prio || $prio eq 'inherit') ? undef : $prio);

    my $schema = $self->schema;
    my $group  = $schema->resultset("JobGroups")->find({id => $self->param('group_id')});

    if ($group && $group->template) {
        # An existing group with a YAML template must not be updated manually
        $error = 'Group "' . $group->name . '" must be updated through the YAML template';
    }
    elsif ($has_product_id) {
        for my $param (qw(machine_id group_id test_suite_id)) {
            $validation->required($param)->like($is_number_regex);
        }

        if ($validation->has_error) {
            $error = "wrong parameter:";
            for my $k (qw(product_id machine_id test_suite_id group_id)) {
                $error .= ' ' . $k if $validation->has_error($k);
            }
        }
        else {
            my $values = {
                prio          => $prio,
                product_id    => $self->param('product_id'),
                machine_id    => $self->param('machine_id'),
                group_id      => $self->param('group_id'),
                test_suite_id => $self->param('test_suite_id')};
            eval { $id = $schema->resultset("JobTemplates")->create($values)->id };
            $error = $@;
        }
    }
    elsif ($self->param('prio_only')) {
        for my $param (qw(group_id test_suite_id)) {
            $validation->required($param)->like($is_number_regex);
        }

        if ($validation->has_error) {
            $error = "wrong parameter:";
            for my $k (qw(group_id test_suite_id prio)) {
                $error .= ' ' . $k if $validation->has_error($k);
            }
        }
        else {
            eval {
                $affected_rows = $schema->resultset("JobTemplates")->search(
                    {
                        group_id      => $self->param('group_id'),
                        test_suite_id => $self->param('test_suite_id'),
                    }
                )->update(
                    {
                        prio => $prio,
                    });
            };
            $error = $@;
        }
    }
    else {
        for my $param (qw(group_name machine_name test_suite_name arch distri flavor version)) {
            $validation->required($param);
        }

        if ($validation->has_error) {
            $error = "wrong parameter:";
            for my $k (qw(group_name machine_name test_suite_name arch distri flavor version)) {
                $error .= ' ' . $k if $validation->has_error($k);
            }
        }
        else {
            my $values = {
                product => {
                    arch    => $self->param('arch'),
                    distri  => $self->param('distri'),
                    flavor  => $self->param('flavor'),
                    version => $self->param('version')
                },
                group      => {name => $self->param('group_name')},
                machine    => {name => $self->param('machine_name')},
                prio       => $prio,
                test_suite => {name => $self->param('test_suite_name')}};
            eval { $id = $schema->resultset("JobTemplates")->create($values)->id };
            $error = $@;
        }
    }

    my $status;
    my $json = {};

    if ($error) {
        $self->app->log->error($error);
        $json->{error} = $error;
        $status = 400;
    }
    else {
        if (defined($affected_rows)) {
            $json->{affected_rows} = $affected_rows;
            $self->emit_event('openqa_jobtemplate_create', {affected_rows => $affected_rows});
        }
        else {
            $json->{id} = $id;
            $self->emit_event('openqa_jobtemplate_create', {id => $id});
        }
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
    my $self          = shift;
    my $job_templates = $self->schema->resultset('JobTemplates');

    my $status;
    my $error;
    my $json = {};

    my $job_template = $job_templates->find({id => $self->param('job_template_id')});
    if ($job_template && $job_template->group->template) {
        # A test suite that is part of a group with a YAML template must not be deleted manually
        $error  = 'Test suites in group "' . $job_template->group->name . '" must be updated through the YAML template';
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
        $error  = 'Not found';
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
