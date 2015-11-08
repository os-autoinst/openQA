# Copyright (C) 2015 SUSE LLC
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

package OpenQA::WebAPI::Controller::Admin::Needle;
use Mojo::Base 'Mojolicious::Controller';
use OpenQA::Utils;

sub index {
    my ($self) = @_;

    my $needles = $self->db->resultset("Needles")->search(undef, {order_by => 'filename'});
    $self->stash('needles', $needles);

    $self->render('admin/needle/index');
}

sub module {
    my ($self) = @_;

    my $module = $self->db->resultset('JobModules')->find($self->param('module_id'));
    my $needle = $self->db->resultset('Needles')->find($self->param('needle_id'))->name;

    use Data::Dumper;
    my $index = 1;
    for my $detail (@{$module->details}) {
        print "NEEDLE $needle - $detail->{needle}\n";
        last if $detail->{needle} eq $needle;
        last if grep { $needle eq $_->{name} } @{$detail->{needles} || []};
        $index++;
    }
    $self->redirect_to('step', testid => $module->job_id, moduleid => $module->name(), stepid => $index);
}

1;
# vim: set sw=4 et:
