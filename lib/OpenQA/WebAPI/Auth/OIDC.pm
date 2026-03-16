# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Auth::OIDC;
use Mojo::Base -base, -signatures;

use Carp 'croak';
use Mojo::Util qw(dumper);
use OpenQA::Log qw(log_debug);
use MIME::Base64 qw(decode_base64url);
use Mojo::JSON qw(decode_json);

sub auth_setup ($server) {
    my $app = $server->app;
    my $config = $app->config->{oidc};

    my $params = {
        args => [
            authorize_url => $config->{authorize_url},
            token_url => $config->{token_url},
        ],
        config => {
            id_from => "sub",
            nickname_from => "preferred_username",
            groups_from => $config->{groups_from},
            access_group => $config->{access_group},
        },
    };
    croak "OIDC provider 'oidc' not supported" unless $params;

    my %provider_args = (key => $config->{key}, secret => $config->{secret}, @{$params->{args}});
    $config->{provider_config} = $params->{config};
    $app->plugin(OAuth2 => {oidc => \%provider_args});
}

sub update_user ($controller, $main_config, $provider_config, $data) {
    return undef unless $data;    # redirect to ID provider

    # get or update user details
    my $id_token = $data->{id_token};
    my ($header_b64, $payload_b64, $signature_b64) = split /\./, $id_token;
    my $details = decode_json(decode_base64url($payload_b64));
    my $id_field = $provider_config->{id_from} // 'id';
    my $nickname_field = $provider_config->{nickname_from};
    my $groups_field = $provider_config->{groups_from};
    if (ref $details ne 'HASH' || !$details->{$id_field} || !$details->{$nickname_field}) {
        log_debug('OIDC user provider returned: ' . dumper($details));
        return $controller->render(text => 'User data returned by OIDC provider is insufficient', status => 403);
    }
    if (defined $details->{$groups_field}) {
        my %groups = map { $_ => 1 } $details->{$groups_field};
        if ($groups{$provider_config->{access_group}}) {
            return $controller->render(text => 'User is not member of configured group.', status => 401);
        }
    }
    else {
        return $controller->render(text => 'User is not member of configured group.', status => 401);
    }
    my $user = $controller->schema->resultset('Users')->create_user(
        $details->{$id_field},
        provider => "oidc\@$details->{iss}",
        nickname => $details->{$nickname_field},
        fullname => $details->{name},
        email => $details->{email});

    $controller->session->{user} = $user->username;
    $controller->redirect_to('index');
}

sub auth_login ($controller) {
    croak 'Config was not parsed' unless my $main_config = $controller->app->config->{oidc};
    croak 'Setup was not called' unless my $provider_config = $main_config->{provider_config};

    my $base_url = $controller->app->config->{global}->{base_url};
    my $host = $base_url ? Mojo::URL->new($base_url)->host : $controller->req->url->host;
    my $get_token_args = {
        redirect_uri => $controller->url_for('login')->userinfo(undef)->host($host)->to_abs,
        scope => "openid"
    };
    $controller->oauth2->get_token_p(oidc => $get_token_args)
      ->then(sub ($data) { update_user($controller, $main_config, $provider_config, $data) })
      ->catch(sub ($error) { $controller->render(text => $error, status => 403) });
    return (manual => 1);
}

1;
