# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::VcsProvider;

use Mojo::Base -base, -signatures;
use Mojo::JSON qw(encode_json);
use Mojo::URL;

has 'app';

sub report_status_to_github ($self, $statuses_url, $params, $scheduled_product_id, $base_url, $callback = undef) {
    $params->{context} //= 'openqa';
    $params->{description} //= 'openQA test run';
    $params->{target_url} //= "$base_url/admin/productlog?id=$scheduled_product_id"
      if $scheduled_product_id && $base_url;

    my $url = Mojo::URL->new($statuses_url);
    my $app = $self->app;
    my $ua = $app->ua;
    my $tx = $ua->build_tx(POST => $url);
    my $req = $tx->req;
    my $headers = $req->headers;
    my $json = encode_json($params);
    $req->body($json);
    $headers->content_type('application/json');
    $headers->content_length(length $json);
    $headers->header(Accept => 'application/vnd.github+json');
    $self->add_provider_headers($req);
    $ua->start($tx, $callback);
    return $tx;
}


package OpenQA::VcsProvider::Github;
use Mojo::Base 'OpenQA::VcsProvider', -signatures;

sub add_provider_headers ($self, $req) {
    my $github_token = $self->app->config->{secrets}->{github_token};
    $req->headers->header(Authorization => "Bearer $github_token");
    $req->headers->header('X-GitHub-Api-Version' => '2022-11-28');
}

package OpenQA::VcsProvider::Gitea;
use Mojo::Base 'OpenQA::VcsProvider', -signatures;

1;
