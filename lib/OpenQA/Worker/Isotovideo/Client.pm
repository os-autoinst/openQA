# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Worker::Isotovideo::Client;
use Mojo::Base -base;

use Mojo::UserAgent;
use OpenQA::Utils qw(log_warning);

has job => undef, weak => 1;
has ua  => sub { Mojo::UserAgent->new };

sub status {
    my ($self, $callback) = @_;
    my $url = $self->url . '/isotovideo/status';
    $self->ua->get(
        $url => sub {
            my ($ua, $tx) = @_;
            if (my $err = $tx->error) {
                log_warning(qq{Unable to query isotovideo status via "$url": $err->{message}});
            }
            my $status_from_os_autoinst = $tx->res->json;
            $self->$callback($status_from_os_autoinst);
        });
}

sub url {
    my $self = shift;
    return undef unless my $info = $self->job->info;
    return $info->{URL};
}

1;
