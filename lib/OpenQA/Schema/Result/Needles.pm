# Copyright (C) 2015-2017 SUSE LLC
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

package OpenQA::Schema::Result::Needles;

use 5.018;
use strict;
use warnings;

use base 'DBIx::Class::Core';

use DBIx::Class::Timestamps 'now';
use File::Basename;
use Cwd 'realpath';
use File::Spec::Functions 'catdir';
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Utils qw(log_error commit_git);

use db_helpers;

__PACKAGE__->table('needles');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    dir_id => {
        data_type   => 'integer',
        is_nullable => 0,
    },
    filename => {
        data_type => 'text',
    },
    last_seen_time => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    last_seen_module_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    last_matched_time => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    last_matched_module_id => {
        data_type   => 'integer',
        is_nullable => 1,
    },
    # last time the needle itself was actually updated (and not just some column modified)
    last_updated => {
        data_type   => 'timestamp',
        is_nullable => 1,
    },
    file_present => {
        data_type     => 'boolean',
        is_nullable   => 0,
        default_value => 1,
    },
    tags => {
        data_type   => 'text[]',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;

__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(dir_id filename)]);
__PACKAGE__->belongs_to(
    last_seen => 'OpenQA::Schema::Result::JobModules',
    'last_seen_module_id', {join_type => 'LEFT', on_delete => 'SET NULL'});
__PACKAGE__->belongs_to(
    last_match => 'OpenQA::Schema::Result::JobModules',
    'last_matched_module_id', {join_type => 'LEFT', on_delete => 'SET NULL'});
__PACKAGE__->belongs_to(directory => 'OpenQA::Schema::Result::NeedleDirs', 'dir_id');

# override insert to ensure new needles have 'last_updated' set
sub insert {
    my ($self, @args) = @_;
    $self->next::method(@args);
    $self->update({last_updated => $self->t_updated});
}

sub update_needle_cache {
    my ($needle_cache) = @_;

    for my $needle (values %$needle_cache) {
        $needle->update;
    }
}

# save the needle informations
# be aware that giving the optional needle_cache hash ref, makes you responsible
# to call update_needle_cache after a loop
sub update_needle {
    my ($filename, $module, $matched, $needle_cache) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    my $guard  = $schema->txn_scope_guard;

    if (!-f $filename) {
        $filename = catdir($OpenQA::Utils::sharedir, $filename);
        if (!-f $filename) {
            log_error(
                "Needle file $filename not found where expected. Check $OpenQA::Utils::prjdir for distri symlinks");
        }
    }
    my $needle;
    if ($needle_cache) {
        $needle = $needle_cache->{$filename};
    }
    if (!$needle) {
        # create a canonical path out of it
        my $realpath       = realpath($filename);
        my $needledir_path = realpath($module->job->needle_dir());
        my $dir;
        my $basename;
        if (index($realpath, $needledir_path) != 0) {    # leave old behaviour as it is
            $dir      = $schema->resultset('NeedleDirs')->find_or_new({path => dirname($realpath)});
            $basename = basename($realpath);
        }
        else {
            $dir = $schema->resultset('NeedleDirs')->find_or_new({path => $needledir_path});
            # basename should contain relative path to json in needledir
            $basename = substr $realpath, length($needledir_path) + 1, length($realpath);
        }
        if (!$dir->in_storage) {
            # first job seen defines the name
            $dir->set_name_from_job($module->job);
            $dir->insert;
        }
        $needle ||= $dir->needles->find_or_new({filename => $basename}, {key => 'needles_dir_id_filename'});
    }

    # it's not impossible that two instances update this information independent of each other, but we don't mind
    # the *exact* last module as long as it's alive around the same time
    if (($needle->last_seen_module_id // 0) < $module->id) {
        $needle->last_seen_module_id($module->id);
        $needle->last_seen_time(now());
    }

    if ($matched && ($needle->last_matched_module_id // 0) < $module->id) {
        $needle->last_matched_module_id($module->id);
        $needle->last_matched_time(now());
    }

    if ($needle->in_storage) {
        # if a cache is given, the caller needs to update all needles after the call
        $needle->update unless $needle_cache;
    }
    else {
        $needle->check_file;
        $needle->insert;
    }
    $needle_cache->{$filename} = $needle;

    $guard->commit;
    return $needle;
}

sub name() {
    my ($self) = @_;
    my ($name, $dir, $extension) = fileparse($self->filename, qw(.json));
    return $name;
}

sub path {
    my ($self) = @_;

    return $self->directory->path . "/" . $self->filename;
}

sub remove {
    my ($self, $user) = @_;

    my $fname      = $self->path;
    my $screenshot = $fname =~ s/.json$/.png/r;
    $OpenQA::Utils::app->log->debug("Remove needle $fname and $screenshot");

    if (($OpenQA::Utils::app->config->{global}->{scm} || '') eq 'git') {
        my $args = {
            dir     => $self->directory->path,
            rm      => [$fname, $screenshot],
            user    => $user,
            message => sprintf("admin remove of %s/%s", $self->directory->name, $self->filename)};
        my $error = commit_git($args);
        return $error if $error;
    }
    else {
        my @error_files;
        unlink($fname)      or push(@error_files, $fname);
        unlink($screenshot) or push(@error_files, $screenshot);
        if (@error_files) {
            my $error = 'Unable to delete ' . join(' and ', @error_files);
            $OpenQA::Utils::app->log->debug($error);
            return $error;
        }
    }
    $self->check_file;
    $self->update;
    return 0;
}

sub check_file {
    my ($self) = @_;

    return $self->file_present(-e $self->path ? 1 : 0);
}

sub to_json {
    my ($self, $controller) = @_;

    my $needle_id = $self->id;
    return {
        id         => $needle_id,
        name       => $self->name,
        directory  => $self->directory->name,
        tags       => $self->tags,
        t_created  => $self->t_created->datetime() . 'Z',
        t_updated  => $self->t_updated->datetime() . 'Z',
        json_path  => "/needles/$needle_id/json",
        image_path => "/needles/$needle_id/image",
    };
}

1;
