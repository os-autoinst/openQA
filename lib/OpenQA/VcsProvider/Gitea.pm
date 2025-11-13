# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::VcsProvider::Gitea;

use Mojo::Base 'OpenQA::VcsProvider::Base', -signatures;

sub read_settings ($self, $settings) {
    $self->statuses_url($settings->{GITEA_STATUSES_URL});
    $self->base_url($settings->{CI_TARGET_URL});
    return undef unless $self->statuses_url;
    return 1;
}

sub create_request ($self, $params) {
    my $tx = $self->SUPER::create_request($params);

    my $headers = $tx->req->headers;
    # TODO there might be more than one gitea server -> add sections?
    my $token = $self->app->config->{secrets}->{gitea_token};
    $headers->header(Accept => 'application/json');
    $headers->header(Authorization => "Bearer $token");

    return $tx;
}

1;
