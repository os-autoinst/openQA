# Copyright (C) 2020 SUSE LLC
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
use Mojo::Base -base;

use Carp 'croak';

has config => undef;

sub auth_setup {
    my ($self) = @_;
    $self->config(my $config = $self->app->config->{oauth2});
    croak 'No OAuth2 provider selected' unless my $provider = $config->{provider};
    my $prov_args = {
        key    => $self->config->{key},
        secret => $self->config->{secret},
    };
    # I'm afraid I don't quite get where I should tuck this away so that I get
    # to use it in auth_login, so I'm doing this FIXME_oauth2_ nastiness for
    # now. I had hoped to tack this onto $prov_args somehow, but I don't know
    # how to then access that later.
    if ($provider eq 'github') {
        $self->config->{FIXME_oauth2_user_url} = 'https://api.github.com/user';
        # Note: user:email is GitHub-specific, email may be empty
        $self->config->{FIXME_oauth2_token_scope} = 'user:email';
        $self->config->{FIXME_oauth2_token_label} = 'token';
        $self->config->{FIXME_oauth2_nickname_from} = 'login';
    }
    elsif ('debian_salsa' eq $provider) {
        $prov_args->{authorize_url} = 'https://salsa.debian.org/oauth/authorize?response_type=code';
        $prov_args->{token_url} = 'https://salsa.debian.org/oauth/token';
        $self->config->{FIXME_oauth2_user_url} = 'https://salsa.debian.org/api/v4/user';
        $self->config->{FIXME_oauth2_token_scope} = 'read_user';
        $self->config->{FIXME_oauth2_token_label} = 'Bearer';
        $self->config->{FIXME_oauth2_nickname_from} = 'username';
    }
    elsif ('custom' eq $provider) {
        $prov_args->{authorize_url} = $self->config->{authorize_url};
        $prov_args->{token_url} = $self->config->{token_url};
        $self->config->{FIXME_oauth2_user_url} = $self->config->{user_url};
        $self->config->{FIXME_oauth2_token_scope} = $self->config->{token_scope};
        $self->config->{FIXME_oauth2_token_label} = $self->config->{token_label};
        $self->config->{FIXME_oauth2_nickname_from} = $self->config->{nickname_from};
    }
    else {
        croak "Provider $provider not supported";
    }

    $self->app->plugin(
        OAuth2 => {
            $provider => $prov_args
        });
}

sub auth_login {
    my ($self) = @_;
    croak 'Setup was not called' unless $self->config;

    my $get_token_args = {redirect_uri => $self->url_for('login')->userinfo(undef)->to_abs};
    $get_token_args->{scope} = $self->config->{FIXME_oauth2_token_scope};
    $self->oauth2->get_token_p($self->config->{provider} => $get_token_args)->then(
        sub {
            return unless my $data = shift;  # redirect to ID provider

            # Get or update user details
            my $ua    = Mojo::UserAgent->new;
            my $token = $data->{access_token};
            my $res   = $ua->get($self->config->{FIXME_oauth2_user_url}, {Authorization => $self->config->{FIXME_oauth2_token_label} . " $token"})->result;
            if (my $err = $res->error) {
                # Note: Using 403 for consistency
                return $self->render(text => "$err->{code}: $err->{message}", status => 403);
            }
            my $details = $res->json;
            my $user    = $self->schema->resultset('Users')->create_user(
                "$details->{id}\@$self->config->{provider}",
                nickname => $details->{$self->config->{FIXME_oauth2_nickname_from}},
                fullname => $details->{name},
                email    => $details->{email});

            $self->session->{user} = $user->username;
            $self->redirect_to('index');
        })->catch(sub { $self->render(text => shift, status => 403) });
    return (manual => 1);
}

1;
