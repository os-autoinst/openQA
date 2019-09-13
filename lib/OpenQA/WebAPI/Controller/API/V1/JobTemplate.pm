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
            $yaml->{$group} = "'$group': |\n" . ($yaml->{$group} =~ s/(.+)\n/  $1\n/gr);
        }
    }
    $self->render(yaml => join("\n", map { $yaml->{$_} } keys %$yaml));
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
        foreach my $arch (keys %{$group{scenarios}}) {
            $group{defaults}{$arch}{priority} = $group->default_priority;
            my $default_machine
              = (sort { $machines{$arch}->{$b} <=> $machines{$arch}->{$a} or $b cmp $a } keys %{$machines{$arch}})[0];
            $group{defaults}{$arch}{machine} = $default_machine;

            foreach my $product (keys %{$group{scenarios}->{$arch}}) {
                my @scenarios;
                foreach my $test_suite (@{$group{scenarios}->{$arch}->{$product}}) {
                    foreach my $name (keys %$test_suite) {
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

    my $schema                = $self->schema;
    my $job_groups            = $schema->resultset('JobGroups');
    my $job_templates         = $schema->resultset('JobTemplates');
    my $job_template_settings = $schema->resultset('JobTemplateSettings');
    my $machines              = $schema->resultset('Machines');
    my $test_suites           = $schema->resultset('TestSuites');
    my $products              = $schema->resultset('Products');
    my $json                  = {};

    try {
        $schema->txn_do(
            sub {
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

                # Add/update job templates from YAML data
                # (create test suites if not already present, fail if referenced machine and product is missing)
                my @job_template_ids;
                my $yaml_archs    = $yaml->{scenarios};
                my $yaml_products = $yaml->{products};
                my $yaml_defaults = $yaml->{defaults};
                foreach my $arch (keys %$yaml_archs) {
                    my $yaml_products_for_arch = $yaml_archs->{$arch};
                    my $yaml_defaults_for_arch = $yaml_defaults->{$arch};
                    foreach my $product_name (keys %$yaml_products_for_arch) {
                        # Keep track of job template names to be able to fail on duplicates
                        my %job_template_names;
                        foreach my $spec (@{$yaml_products_for_arch->{$product_name}}) {
                            # Get testsuite, machine, prio and job template settings from YAML data
                            my $testsuite_name;
                            my $job_template_name;
                            my $prio;
                            my $machine_name;
                            my %settings = %{$yaml_defaults_for_arch->{settings} // {}};
                            if (ref $spec eq 'HASH') {
                                foreach my $name (keys %$spec) {
                                    my $attr = $spec->{$name};
                                    $testsuite_name = $name;
                                    if ($attr->{priority}) {
                                        $prio = $attr->{priority};
                                    }
                                    if ($attr->{machine}) {
                                        $machine_name = $attr->{machine};
                                    }
                                    if ($attr->{testsuite}) {
                                        $testsuite_name    = $attr->{testsuite};
                                        $job_template_name = $testsuite_name;
                                    }
                                    if ($attr->{settings}) {
                                        %settings = (%settings, %{$attr->{settings}});
                                    }
                                }
                            }
                            else {
                                $testsuite_name = $spec;
                            }

                            # Assign defaults
                            $prio         //= $yaml_defaults_for_arch->{priority};
                            $machine_name //= $yaml_defaults_for_arch->{machine};
                            die "Machine is empty and there is no default for architecture $arch\n"
                              unless $machine_name;

                            my $job_template_key
                              = $product_name . $machine_name . $testsuite_name . ($job_template_name // '');
                            die "Job template name '"
                              . ($job_template_name // $testsuite_name)
                              . "' is defined more than once. "
                              . "Use a unique name and specify 'testsuite' to re-use test suites in multiple scenarios.\n"
                              if $job_template_names{$job_template_key};
                            $job_template_names{$job_template_key}++;

                            # Find machine, product and testsuite
                            my $machine = $machines->find({name => $machine_name});
                            die "Machine '$machine_name' is invalid\n" unless $machine;
                            my $product_spec = $yaml_products->{$product_name};
                            my $product      = $products->find(
                                {
                                    arch    => $arch,
                                    distri  => $product_spec->{distri},
                                    flavor  => $product_spec->{flavor},
                                    version => $product_spec->{version},
                                });
                            die "Product '$product_name' is invalid\n" unless $product;
                            my $test_suite = $test_suites->find({name => $testsuite_name});
                            die "Testsuite '$testsuite_name' is invalid\n" unless $test_suite;

                            # Create/update job template
                            my $job_template = $job_templates->find_or_create(
                                {
                                    group_id      => $group_id,
                                    product_id    => $product->id,
                                    machine_id    => $machine->id,
                                    name          => $job_template_name,
                                    test_suite_id => $test_suite->id,
                                });
                            my $job_template_id = $job_template->id;
                            $job_template->update({prio => $prio}) if (defined $prio);
                            push(@job_template_ids, $job_template->id);

                            # Add/update/remove parameter
                            my @setting_ids;
                            if (%settings) {
                                foreach my $key (keys %settings) {
                                    my $setting = $job_template_settings->find(
                                        {
                                            job_template_id => $job_template_id,
                                            key             => $key,
                                        });
                                    if ($setting) {
                                        $setting->update({value => $settings{$key}});
                                    }
                                    else {
                                        $setting = $job_template_settings->find_or_create(
                                            {
                                                job_template_id => $job_template_id,
                                                key             => $key,
                                                value           => $settings{$key},
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

                            # Stop iterating if there were errors with this test suite
                            last if (@$errors);
                        }
                    }
                }

                # Drop entries we haven't touched in add/update loop
                $job_templates->search(
                    {
                        id       => {'not in' => \@job_template_ids},
                        group_id => $group_id,
                    })->delete();

                # Preview mode: Get the expected YAML and rollback the result
                if ($self->param('preview')) {
                    $json->{changes} = "\n" . diff \$job_group->template, \$self->param('template')
                      if $job_group->template && $job_group->template ne $self->param('template');
                    $json->{preview} = int($self->param('preview'));
                    $self->schema->txn_rollback;
                }
                else {
                    $json->{changes} = "\n" . diff \$job_group->template, \$self->param('template')
                      if $job_group->template && $job_group->template ne $self->param('template');
                    # Store the original YAML template after all changes have been made
                    $job_group->update({template => $self->param('template')});
                }
                if ($json->{changes}) {
                    # Remove the warning about new lines. We don't require that!
                    $json->{changes} =~ s/\\ No newline at end of file\n//;
                    # Remove leading and trailing whitespace
                    $json->{changes} =~ s/^\s+|\s+$//g;
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
