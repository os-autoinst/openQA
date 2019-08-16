# Copyright (C) 2019 SUSE Linux GmbH
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
# with this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

package OpenQA::WebAPI::Plugin::ObsRsync::Controller;
use Mojo::Base 'Mojolicious::Controller';

sub _home {
    return shift->obs_rsync->home;
}

sub _check_and_render_error {
    my $self = $_[0];
    my ($code, $message) = _check_error(@_);
    $self->render(json => {error => $message}, status => $code) if $code;
    return $code;
}

sub _check_error {
    my ($self, $project, $subfolder, $filename) = @_;
    my $home = $self->_home;
    return (405, "Home directory is not set") unless $home;
    return (405, "Home directory not found")  unless -d $home;
    return (400, "Project has invalid characters")   if $project   && $project =~ m!/!;
    return (400, "Subfolder has invalid characters") if $subfolder && $subfolder =~ m!/!;
    return (400, "Filename has invalid characters")  if $filename  && $filename =~ m!/!;

    return (404, "Invalid Project {" . $project . "}") if $project && !-d Mojo::File->new($home, $project);
    return 0;
}

1;
