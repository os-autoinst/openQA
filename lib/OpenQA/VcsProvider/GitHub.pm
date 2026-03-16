# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::VcsProvider::GitHub;

use Mojo::Base 'OpenQA::VcsProvider::Base', -signatures;

sub read_settings ($self, $settings) {
    $self->statuses_url($settings->{GITHUB_STATUSES_URL});
    $self->base_url($settings->{CI_TARGET_URL});
    return undef unless $self->statuses_url;
    return 1;
}

sub create_request ($self, $params) {
    my $tx = $self->SUPER::create_request($params);

    my $headers = $tx->req->headers;
    my $github_token = $self->app->config->{secrets}->{github_token};
    $headers->header(Accept => 'application/vnd.github+json');
    $headers->header(Authorization => "Bearer $github_token");
    $headers->header('X-GitHub-Api-Version' => '2022-11-28');

    return $tx;
}

1;
