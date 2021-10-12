# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::OAuth2;
use Mojo::Base -base, -signatures;
use Carp 'croak';
use Data::Dumper;
use OpenQA::Log qw(log_debug);

sub auth_setup ($server) {
    my $app = $server->app;
    my $config = $app->config->{oauth2};
    croak 'No OAuth2 provider selected' unless my $provider = $config->{provider};

    my %parameters_by_provider = (
        github => {
            args => [],
            config => {
                user_url => 'https://api.github.com/user',
                token_scope => 'user:email',
                token_label => 'token',
                nickname_from => 'login',
            },
        },
        debian_salsa => {
            args => [
                authorize_url => 'https://salsa.debian.org/oauth/authorize?response_type=code',
                token_url => 'https://salsa.debian.org/oauth/token',
            ],
            config => {
                user_url => 'https://salsa.debian.org/api/v4/user',
                token_scope => 'read_user',
                token_label => 'Bearer',
                nickname_from => 'username',
            },
        },
        custom => {
            args => [
                authorize_url => $config->{authorize_url},
                token_url => $config->{token_url},
            ],
            config => {
                user_url => $config->{user_url},
                token_scope => $config->{token_scope},
                token_label => $config->{token_label},
                nickname_from => $config->{nickname_from},
                unique_name => $config->{unique_name},
            },
        },
    );
    my $params = $parameters_by_provider{$provider};
    croak "OAuth2 provider '$provider' not supported" unless $params;

    my %provider_args = (key => $config->{key}, secret => $config->{secret}, @{$params->{args}});
    $config->{provider_config} = $params->{config};
    $app->plugin(OAuth2 => {$provider => \%provider_args});
}

sub update_user ($controller, $main_config, $provider_config, $data) {
    return undef unless $data;    # redirect to ID provider

    # get or update user details
    my $ua = Mojo::UserAgent->new;
    my $token = $data->{access_token};
    my $tx = $ua->get($provider_config->{user_url}, {Authorization => "$provider_config->{token_label} $token"});
    if (my $err = $tx->error) {
        my $msg = $err->{code} ? "$err->{code} response: $err->{message}" : "Connection error: $err->{message}";
        return $controller->render(text => $msg, status => 403);    # return always 403 for consistency
    }
    my $details = $tx->res->json;
    if (ref $details ne 'HASH' || !$details->{id} || !$details->{$provider_config->{nickname_from}}) {
        log_debug("OAuth2 user provider returned: " . Dumper($details));
        return $controller->render(text => 'User data returned by OAuth2 provider is insufficient', status => 403);
    }
    my $provider_name = $main_config->{provider};
    $provider_name = $provider_config->{unique_name} || $provider_name if $provider_name eq 'custom';
    my $user = $controller->schema->resultset('Users')->create_user(
        $details->{id},
        provider => "oauth2\@$provider_name",
        nickname => $details->{$provider_config->{nickname_from}},
        fullname => $details->{name},
        email => $details->{email});

    $controller->session->{user} = $user->username;
    $controller->redirect_to('index');
}

sub auth_login ($controller) {
    croak 'Config was not parsed' unless my $main_config = $controller->app->config->{oauth2};
    croak 'Setup was not called' unless my $provider_config = $main_config->{provider_config};

    my $get_token_args = {redirect_uri => $controller->url_for('login')->userinfo(undef)->to_abs};
    $get_token_args->{scope} = $provider_config->{token_scope};
    $controller->oauth2->get_token_p($main_config->{provider} => $get_token_args)
      ->then(sub { update_user($controller, $main_config, $provider_config, shift) })
      ->catch(sub { $controller->render(text => shift, status => 403) });
    return (manual => 1);
}

1;
