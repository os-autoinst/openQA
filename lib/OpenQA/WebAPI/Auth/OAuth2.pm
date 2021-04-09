# Copyright (C) 2020-2021 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

package OpenQA::WebAPI::Auth::OAuth2;
use Mojo::Base -base, -signatures;
use Carp 'croak';

sub auth_setup ($server) {
    my $app    = $server->app;
    my $config = $app->config->{oauth2};
    croak 'No OAuth2 provider selected' unless my $provider = $config->{provider};

    my %parameters_by_provider = (
        github => {
            args   => [],
            config => {
                user_url      => 'https://api.github.com/user',
                token_scope   => 'user:email',
                token_label   => 'token',
                nickname_from => 'login',
            },
        },
        debian_salsa => {
            args => [
                authorize_url => 'https://salsa.debian.org/oauth/authorize?response_type=code',
                token_url     => 'https://salsa.debian.org/oauth/token',
            ],
            config => {
                user_url      => 'https://salsa.debian.org/api/v4/user',
                token_scope   => 'read_user',
                token_label   => 'Bearer',
                nickname_from => 'username',
            },
        },
        custom => {
            args => [
                authorize_url => $config->{authorize_url},
                token_url     => $config->{token_url},
            ],
            config => {
                user_url      => $config->{user_url},
                token_scope   => $config->{token_scope},
                token_label   => $config->{token_label},
                nickname_from => $config->{nickname_from},
            },
        },
    );
    my $params = $parameters_by_provider{$provider};
    croak "OAuth2 provider '$provider' not supported" unless $params;

    my %provider_args = (key => $config->{key}, secret => $config->{secret}, @{$params->{args}});
    $config->{provider_config} = $params->{config};
    $app->plugin(OAuth2 => {$provider => \%provider_args});
}

sub auth_login ($controller) {
    croak 'Config was not parsed' unless my $main_config     = $controller->app->config->{oauth2};
    croak 'Setup was not called'  unless my $provider_config = $main_config->{provider_config};

    my $get_token_args = {redirect_uri => $controller->url_for('login')->userinfo(undef)->to_abs};
    $get_token_args->{scope} = $provider_config->{token_scope};
    $controller->oauth2->get_token_p($main_config->{provider} => $get_token_args)->then(
        sub {
            return undef unless my $data = shift;    # redirect to ID provider

            # Get or update user details
            my $ua    = Mojo::UserAgent->new;
            my $token = $data->{access_token};
            my $res
              = $ua->get($provider_config->{user_url}, {Authorization => "$provider_config->{token_label} $token"})
              ->result;
            if (my $err = $res->error) {
                # Note: Using 403 for consistency
                return $controller->render(text => "$err->{code}: $err->{message}", status => 403);
            }
            my $details = $res->json;
            my $user    = $controller->schema->resultset('Users')->create_user(
                $details->{id},
                provider => "oauth2\@$main_config->{provider}",
                nickname => $details->{$provider_config->{nickname_from}},
                fullname => $details->{name},
                email    => $details->{email});

            $controller->session->{user} = $user->username;
            $controller->redirect_to('index');
        })->catch(sub { $controller->render(text => shift, status => 403) });
    return (manual => 1);
}

1;
