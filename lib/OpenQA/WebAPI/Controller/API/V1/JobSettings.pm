# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::JobSettings;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use OpenQA::Jobs::Constants qw(NOT_OK_RESULTS);

sub jobs ($self) {
    my $validation = $self->validation;
    $validation->required('key')->like(qr/^[\w\*]+$/);
    $validation->required('list_value')->like(qr/^\w+$/);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $key = $validation->param('key');
    my $list_value = $validation->param('list_value');
    my $jobs = $self->schema->resultset('JobSettings')->jobs_for_setting({key => $key, list_value => $list_value});
    $self->render(json => {jobs => $jobs});
}

sub failed_jobs ($self) {
    my $validation = $self->validation;
    $validation->required('key')->like(qr/^[\w\*]+$/);
    $validation->required('list_value')->like(qr/^\w+$/);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $key = $validation->param('key');
    my $list_value = $validation->param('list_value');
    my @list_result = NOT_OK_RESULTS;
    my $jobs = $self->schema->resultset('JobSettings')
      ->jobs_for_setting({key => $key, list_value => $list_value, list_result => \@list_result});
    $self->render(json => {jobs => $jobs});
}

1;
