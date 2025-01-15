# Copyright 2014 SUSE LLC
#           (C) 2015 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Table;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::Util qw(trim xml_escape);
use OpenQA::App;
use OpenQA::Log 'log_debug';
use List::Util qw(min);
use Try::Tiny;
use Mojo::JSON 'decode_json';

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Table

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Table;

=head1 DESCRIPTION

OpenQA API implementation for table handling.

Within this package, three types of tables are handled:

=over 4

=item Machines

Machines are defined by id, name, a backend and a description. Only the id and the backend are
always required.

=item Test Suites

Test Suites are defined by id, name and description. Only the name is always required.

=item Products

Products are defined by id, distri, version, arch, flavor and description. The distri,
version, arch and flavor parameters are always required.

=back

=head1 METHODS

=cut

my %TABLES = (
    Machines => {
        keys => [['id'], ['name'],],
        cols => ['id', 'name', 'backend', 'description'],
        required => ['name', 'backend'],
        defaults => {description => undef},
        ref_name => 'machine'
    },
    TestSuites => {
        keys => [['id'], ['name'],],
        cols => ['id', 'name', 'description'],
        required => ['name'],
        defaults => {description => undef},
        ref_name => 'test_suite'
    },
    Products => {
        keys => [['id'], ['distri', 'version', 'arch', 'flavor'],],
        cols => ['id', 'distri', 'version', 'arch', 'flavor', 'description'],
        required => ['distri', 'version', 'arch', 'flavor'],
        defaults => {description => '', name => ''},
        ref_name => 'product'
    },
);

=over 4

=item list()

List the parameters of tables given its type (machine, test suite or product). If an
id is passed as an argument to the method, only information for the passed id is
returned, otherwise all structures of the same type defined in the system are
returned. For further information on the type of parameters associated to each
of the type of tables, check the OpenQA::WebAPI::Controller::API::V1::Table package
documentation.

=back

=cut

sub list ($self) {
    my $schema = $self->schema;
    my $limits = OpenQA::App->singleton->config->{misc_limits};

    my $validation = $self->validation;
    $validation->optional('limit')->num;
    $validation->optional('offset')->num;
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $limit = min($limits->{generic_max_limit}, $validation->param('limit') // $limits->{generic_default_limit});
    my $offset = $validation->param('offset') // 0;

    my $table = $self->stash('table');
    my %search;
    for my $key (@{$TABLES{$table}->{keys}}) {
        my $have = 1;
        for my $par (@$key) {
            $have &&= $self->param($par);
        }
        if ($have) {
            for my $par (@$key) {
                $search{"me.$par"} = $self->param($par);
            }
        }
    }

    my @all;
    eval {
        @all = $schema->resultset($table)->search(
            keys %search ? \%search : undef,
            {
                join => 'settings',
                '+select' => [qw(settings.id settings.key settings.value), "settings.$TABLES{$table}{ref_name}_id"],
                collapse => 1,
                order_by => 'me.id',
                rows => $limit + 1,
                offset => $offset
            });
    };
    if (my $error = $@) {
        return $self->render(json => {error => $error}, status => 404);
    }

    # Pagination
    pop @all if my $has_more = @all > $limit;
    $self->pagination_links_header($limit, $offset, $has_more);

    $self->render(
        json => {
            $table => [
                map {
                    my $row = $_;
                    my @settings = sort { $a->key cmp $b->key } $row->settings;
                    my %hash = (
                        (
                            map {
                                my $val = $row->get_column($_);
                                $val ? ($_ => $val) : ()
                            } @{$TABLES{$table}->{cols}}
                        ),
                        settings => [map { {key => $_->key, value => $_->value} } @settings]);
                    \%hash;
                } @all
            ]});
}

=over 4

=item create()

Creates a new table given its type (machine, test suite or product). Returns the
table id in a JSON block on success or a 400 code on error. For information on the
type of parameters associated to each of the type of tables, as well as which of those
parameters are required and validated when calling this method, check the
OpenQA::WebAPI::Controller::API::V1::Table package documentation.

=back

=cut

sub create {
    my ($self) = @_;
    my $table = $self->param('table');
    my %entry = %{$TABLES{$table}->{defaults}};

    my ($error_message, $settings, $keys) = $self->_prepare_settings($table, \%entry);
    return $self->render(json => {error => $error_message}, status => 400) if defined $error_message;

    $entry{settings} = $settings;

    my $error;
    my $id;

    try { $id = $self->schema->resultset($table)->create(\%entry)->id; } catch { $error = shift; };

    if ($error) {
        return $self->render(json => {error => $error}, status => 400);
    }
    $self->emit_event('openqa_table_create', {table => $table, id => $id, %entry});
    $self->render(json => {id => $id});
}

=over 4

=item update()

Updates the parameters of a table given its type (machine, test suite or product). This
method will check the required parameters for the type of structure before updating. 
For information on the type of parameters associated to each of the type of tables, as
well as which of those parameters are required and validated when calling this method, check
the OpenQA::WebAPI::Controller::API::V1::Table package documentation. Returns a 404 error
code if the table is not found, 400 on other errors or a JSON block containing the number
of tables updated by the method on success.

=back

=cut

sub _verify_table_usage {
    my ($self, $table, $id) = @_;

    my $parameter = {
        Products => 'product_id',
        Machines => 'machine_id',
        TestSuites => 'test_suite_id',
    }->{$table};
    my $job_templates = $self->schema->resultset('JobTemplates')->search({$parameter => $id});
    my %groups;
    while (my $job_template = $job_templates->next) {
        $groups{$job_template->group->name} = 1 if $job_template->group->template;
    }
    return
      scalar(keys %groups)
      ? 'Group'
      . (scalar(keys %groups) > 1 ? 's' : '') . ' '
      . join(', ', sort keys(%groups))
      . ' must be updated through the YAML template'
      : undef;
}

sub update {
    my ($self) = @_;
    my $table = $self->param('table');

    my $entry = {};
    my ($error_message, $settings, $keys) = $self->_prepare_settings($table, $entry);

    return $self->render(json => {error => $error_message}, status => 400) if defined $error_message;

    my $schema = $self->schema;

    my $error;
    my $ret;
    my $update = sub {
        my $rc = $schema->resultset($table)->find({id => $self->param('id')});
        # Tables used in a group configured in YAML must not be renamed
        if (
            (($table eq 'TestSuites' || $table eq 'Machines') && $rc->name ne $self->param('name'))
            || (
                $table eq 'Products'
                && ($rc->arch ne $self->param('arch')
                    || $rc->distri ne $self->param('distri')
                    || $rc->flavor ne $self->param('flavor')
                    || $rc->version ne $self->param('version'))))
        {
            my $error_message = $self->_verify_table_usage($table, $self->param('id'));
            $ret = 0;
            die "$error_message\n" if $error_message;
        }
        if ($rc) {
            $rc->update($entry);
            for my $var (@$settings) {
                $rc->update_or_create_related('settings', $var);
            }
            $rc->delete_related('settings', {key => {'not in' => [@$keys]}});
            $ret = 1;
        }
        else {
            $ret = 0;
        }
    };

    try {
        $schema->txn_do($update);
    }
    catch {
        # The first line of the backtrace gives us the error message we want
        $error = (split /\n/, $_)[0];
    };

    if ($ret && $ret == 0) {
        return $self->render(json => {error => 'Not found'}, status => 404);
    }
    if (!$ret) {
        return $self->render(json => {error => $error}, status => 400);
    }
    $self->emit_event('openqa_table_update', {table => $table, name => $entry->{name}, settings => $settings});
    $self->render(json => {result => int($ret)});
}

=over 4

=item destroy()

Deletes a table given its type (machine, test suite or product) and its id. Returns
a 404 error code when the table is not found, 400 on other errors or a JSON block
with the number of deleted tables on success.

=back

=cut

sub destroy {
    my ($self) = @_;

    my $table = $self->param('table');
    my $schema = $self->schema;
    my $machines = $schema->resultset('Machines');
    my $ret;
    my $error;
    my $res;
    my $entry_name;

    try {
        # Tables used in a group configured in YAML must not be deleted
        my $error_message = $self->_verify_table_usage($table, $self->param('id'));
        die "$error_message\n" if $error_message;

        my $rs = $schema->resultset($table);
        $res = $rs->search({id => $self->param('id')});
        if ($res && $res->single) {
            $entry_name = $res->single->name;
        }
        $ret = $res->delete;
    }
    catch {
        # The first line of the backtrace gives us the error message we want
        $error = (split /\n/, $_)[0];
    };

    if ($ret && $ret == 0) {
        return $self->render(json => {error => 'Not found'}, status => 404);
    }
    if (!$ret) {
        return $self->render(json => {error => $error}, status => 400);
    }
    $self->emit_event('openqa_table_delete', {table => $table, name => $entry_name});
    $self->render(json => {result => int($ret)});
}

=over 4

=item _prepare_settings()

Internal method to prepare settings when add or update admin table.
Use by both B<create()> and B<update()> method.

=back

=cut

sub _prepare_settings {
    my ($self, $table, $entry) = @_;
    my $validation = $self->validation;
    my $hp;
    # accept modern application/json encoded hashes
    my $error;
    if ($self->req->headers->content_type =~ /^application\/json/) {
        try {
            $hp = decode_json($self->req->body);
        }
        catch {
            $error = $_;
        };
        # of course stupid perl doesn't let you return directly from catch
        # as that would actually lead to readable code
        return $error if (defined $error);
        for my $k (keys %{$hp}) {
            # populate json hash entries as params
            $self->param($k, $hp->{$k});
        }
        # make validation work with json request
        $validation->input($hp);
    }
    else {
        return 'Invalid request Content-Type ' . $self->req->headers->content_type . '. Expecting application/json.';
    }

    for my $par (@{$TABLES{$table}->{required}}) {
        $validation->required($par);
        if (!defined $validation->param($par)) {
            next;
        }
        $entry->{$par} = trim $validation->param($par);
    }

    if ($validation->has_error) {
        return 'Missing parameter: ' . join(', ', @{$validation->failed});
    }

    $entry->{description} = $self->param('description');
    my @settings;
    my @keys;
    if ($hp->{settings}) {
        for my $k (keys %{$hp->{settings}}) {
            my $value = trim $hp->{settings}->{$k};
            $k = trim $k;
            my %invalid;
            @invalid{$k =~ m/([^\]\[0-9a-zA-Z_\+])/g} = ();
            if (keys %invalid) {
                my $eick = join ', ', map { '<b>' . xml_escape($_) . '</b>' } sort keys %invalid;
                return sprintf('Invalid characters %s in settings key <b>%s</b>', $eick, xml_escape($k));
            }
            push @settings, {key => $k, value => $value};
            push @keys, $k;
        }
    }
    return (undef, \@settings, \@keys);
}

1;
