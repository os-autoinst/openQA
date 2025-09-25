# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::VcsProvider;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::URL;

has 'app';
has 'statuses_url';

sub read_settings ($self, $settings) {
    $self->statuses_url($settings->{GITHUB_STATUSES_URL});
    return undef unless $self->statuses_url;
    return 1;
}

sub report_status_to_git ($self, $params, $scheduled_product_id, $base_url, $callback = undef) {
    $params->{context} //= 'openqa';
    $params->{description} //= 'openQA test run';
    $params->{target_url} //= "$base_url/admin/productlog?id=$scheduled_product_id"
      if $scheduled_product_id && $base_url;

    my $url = Mojo::URL->new($self->statuses_url);
    my $app = $self->app;
    my $ua = $app->ua;
    my $tx = $ua->build_tx(POST => $url);
    my $req = $tx->req;
    my $headers = $req->headers;
    my $github_token = $app->config->{secrets}->{github_token};
    my $json = encode_json($params);
    $req->body($json);
    $headers->content_type('application/json');
    $headers->content_length(length $json);
    $headers->header(Accept => 'application/vnd.github+json');
    $headers->header(Authorization => "Bearer $github_token");
    $headers->header('X-GitHub-Api-Version' => '2022-11-28');
    $ua->start($tx, $callback);
    return $tx;
}

1;
