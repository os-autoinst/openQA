# Copyright 2014 SUSE LLC
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

package OpenQA::WebAPI::Controller::Admin::JobTemplate;
use Mojo::Base 'Mojolicious::Controller';

sub index {
    my ($self) = @_;

    my $schema = $self->schema;
    my $group  = $schema->resultset('JobGroups')->find($self->param('groupid'));
    return $self->reply->not_found unless $group;

    my $yaml = $group->template;
    my $force_yaml_editor
      = defined $yaml || $schema->resultset('JobTemplates')->search({group_id => $group->id}, {rows => 1})->count == 0;
    $self->stash(
        group             => $group,
        yaml_template     => $yaml,
        force_yaml_editor => $force_yaml_editor,
    );

    my @machines = $schema->resultset("Machines")->search(undef, {order_by => 'name'});
    $self->stash(machines => \@machines);
    my @tests = $schema->resultset("TestSuites")->search(undef, {order_by => 'name'});
    $self->stash(tests => \@tests);

    $self->render('admin/job_template/index');
}

1;
