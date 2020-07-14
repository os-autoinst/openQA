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
    $self->config($self->app->config->{oauth2});
    croak 'No OAuth2 provider selected' unless my $provider = $self->config->{provider};
    croak "Provider $provider not supported" unless $provider eq 'github';

    $self->app->plugin(
        OAuth2 => {
            $provider => {
                key    => $self->config->{key},
                secret => $self->config->{secret},
            }});
}

sub auth_login {
    my ($self) = @_;
    croak 'Setup was not called' unless $self->config;

    my $get_token_args = {redirect_uri => $self->url_for('login')->userinfo(undef)->to_abs};
    # Note: user:email is GitHub-specific, email may be empty
    $get_token_args->{scope} = 'user:email';
    $self->oauth2->get_token_p($self->config->{provider} => $get_token_args)->then(
        sub {
            return unless my $data = shift;

            # Get or update user details via GitHub-specific API
            my $ua    = Mojo::UserAgent->new;
            my $token = $data->{access_token};
            my $res   = $ua->get('https://api.github.com/user', {Authorization => "token $token"})->result;
            if (my $err = $res->error) {
                # Note: Using 403 for consistency
                return $self->render(text => "$err->{code}: $err->{message}", status => 403);
            }
            my $details = $res->json;
            my $user    = $self->schema->resultset('Users')->create_user(
                $details->{id},
                nickname => $details->{login},
                fullname => $details->{name},
                email    => $details->{email});

            $self->session->{user} = $user->username;
            $self->redirect_to('index');
        })->catch(sub { $self->render(text => shift, status => 403) });
    return (manual => 1);
}

1;
