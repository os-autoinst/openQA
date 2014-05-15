# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Admin::VariableHelpers;

sub add_variable {
    my $self = shift;
    my $table = shift;
    my $settings_class = shift;

    my $error;
    my $validation = $self->validation;
    $self->app->log->debug($self->param($table.'_id'));
    #    $validation->required('testsuiteid');
    $validation->required('key')->like(qr/^[[:alnum:]_]+$/);
    $validation->required('value');
    if ($validation->has_error) {
        $error = "wrong parameters.";
        for my $k (qw/key value/) {
            $self->app->log->debug(@{$validation->error($k)}) if $validation->has_error($k);
            $error .= $k if $validation->has_error($k);
        }
    }
    else {
        eval {$self->db->resultset($settings_class)->create({$table.'_id' => $self->param($table.'_id'),key => $self->param('key'),value => $self->param('value')});};
        $error = $@;
    }

    if ($error) {
        $self->flash('error', "Error adding the test suite: $error");
        $self->redirect_to($self->url_for('admin_'.$table.'s'));
    }
    else {
        $self->flash(info => 'Variable '.$self->param('key').' added');
        $self->redirect_to($self->url_for('admin_'.$table.'s'));
    }

}

sub remove_variable {
    my $self = shift;
    my $table = shift; # test_suite
    my $settings_class = shift; # TestSuiteSettings

    $self->app->log->debug("delete var", $self->param('settingid'));

    eval { $self->db->resultset($settings_class)->find({id => $self->param('settingid'),$table.'.id' => $self->param($table.'_id') })->delete };
    my $error = $@;

    if ($error) {
        $self->stash('error', "$error" );
    }
    $self->redirect_to('admin_'.$table.'s');
}

1;
