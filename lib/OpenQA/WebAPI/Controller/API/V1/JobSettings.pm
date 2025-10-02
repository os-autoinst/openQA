# Copyright 2022 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::JobSettings;
use Mojo::Base 'Mojolicious::Controller', -signatures;

=over 4

=item jobs()

Filters jobs based on a single setting key/value pair.

  openqa-cli api job_settings/jobs key="ISSUES[]" value=39911
  openqa-cli api job_settings/jobs key="*_TEST_ISSUES" list_value=39911
  openqa-cli api job_settings/jobs key="*" list_value=39911

=item C<key>

The setting key to filter by. Some variables are not stored and they can not be
used.

=item C<value>

Returns all jobs where the value of the setting specified by C<key> is C<value>.

As this query might find many jobs the results are limited by the server-side
setting C<{misc_limits}{generic_default_limit}>. This limit can be increased
using the C<limit> paremter (up to C<{misc_limits}{generic_max_limit}>).

=item C<list_value>

Returns all jobs where the value of the setting specified by C<key> contains a
comma-separated list that in turn contains C<list_value>. This can be a string
without special characters. When C<list_value> is used, C<key> might contain an
asterisks for globbing.

Use of C<list_value> is expensive so the search is limited via the server-side
setting C<{misc_limits}{job_settings_max_recent_jobs}>.

=item Returns

On success, returns an array of the matched job IDs.

=back

=cut

sub jobs ($self) {
    my $validation = $self->validation;
    $validation->required('key')->like(qr/^[\w\*\[\]]+$/);
    $validation->optional('value');
    $validation->optional('list_value')->like(qr/^\w+$/);
    $validation->optional('limit')->num(0);
    return $self->reply->validation_error({format => 'json'}) if $validation->has_error;

    my $key = $validation->param('key');
    my $value = $validation->param('value');
    my $list_value = $validation->param('list_value');
    my $limit = $validation->param('limit');
    return $self->render(json => {error => 'either "value" or "list_value" needs to be specified'}, status => 400)
      unless defined($value)
      xor defined($list_value);
    my $job_settings = $self->schema->resultset('JobSettings');
    my $options = {key => $key, value => $value, list_value => $list_value, limit => $limit};
    $self->render(json => {jobs => $job_settings->jobs_for_setting($options)});
}

1;
