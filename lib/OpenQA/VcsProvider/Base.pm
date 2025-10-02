# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::VcsProvider::Base;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::URL;

has 'app';
has 'base_url';
has 'statuses_url';

sub add_params ($self, $params, $scheduled_product_id) {
    $params->{context} //= 'openqa';
    $params->{description} //= 'openQA test run';
    my $base_url = $self->base_url;
    $params->{target_url} //= "$base_url/admin/productlog?id=$scheduled_product_id"
      if $scheduled_product_id && $base_url;
}

sub create_request ($self, $params) {
    my $app = $self->app;
    my $ua = $app->ua;
    # TODO Note that anyone who can create an openQA job can set settings
    # with a webhook id and a statuses URL. Maybe we should configure the
    # base url for each git provider and double check the url, because
    # we are making an API request with a token to an otherwise unchecked URL
    my $url = Mojo::URL->new($self->statuses_url);
    my $tx = $ua->build_tx(POST => $url);
    my $req = $tx->req;
    my $json = encode_json($params);
    $req->body($json);
    my $headers = $req->headers;
    $headers->content_type('application/json');
    $headers->content_length(length $json);

    return $tx;
}

sub report_status_to_git ($self, $params, $scheduled_product_id, $callback = undef) {
    $self->add_params($params, $scheduled_product_id);

    my $tx = $self->create_request($params);
    $self->app->ua->start($tx, $callback);
    return $tx;
}

1;
