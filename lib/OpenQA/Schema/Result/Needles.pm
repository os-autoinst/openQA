# Copyright 2015-2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Needles;

## no critic (OpenQA::RedundantStrictWarning)
use 5.018;

use Mojo::Base 'DBIx::Class::Core', -signatures;

use DBIx::Class::Timestamps 'now';
use File::Basename;
use Cwd 'realpath';
use File::Spec::Functions 'catdir';
use OpenQA::App;
use OpenQA::Git;
use OpenQA::Jobs::Constants;
use OpenQA::Schema::Result::Jobs;
use OpenQA::Needles qw(locate_needle);

__PACKAGE__->table('needles');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'bigint',
        is_auto_increment => 1,
    },
    dir_id => {
        data_type => 'bigint',
        is_nullable => 0,
    },
    filename => {
        data_type => 'text',
    },
    last_seen_time => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    last_seen_module_id => {
        data_type => 'bigint',
        is_nullable => 1,
    },
    last_matched_time => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    last_matched_module_id => {
        data_type => 'bigint',
        is_nullable => 1,
    },
    # last time the needle itself was actually updated (and not just some column modified)
    last_updated => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    file_present => {
        data_type => 'boolean',
        is_nullable => 0,
        default_value => 1,
    },
    tags => {
        data_type => 'text[]',
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
# note: Not used by the function update_needle but still required for unit tests that
#       create needles directly.
sub insert ($self, @args) {
    $self->next::method(@args);
    $self->update({last_updated => $self->t_updated});
}

sub update_needle_cache ($needle_cache) { $_->update for values %$needle_cache }

# save the needle information
# be aware that giving the optional needle_cache hash ref, makes you responsible
# to call update_needle_cache after a loop
sub update_needle ($filename, $module, $matched = undef, $needle_cache = undef) {
    # assume that path of the JSON file is relative to the job's needle dir
    my $job = $module->job;
    my $needle_dir = $job->needle_dir;
    return undef unless -f $filename || ($filename = locate_needle($filename, $needle_dir));

    my $schema = OpenQA::Schema->singleton;
    my $guard = $schema->txn_scope_guard;
    my $needle = $needle_cache ? $needle_cache->{$filename} : undef;
    my $needle_id;

    # find/insert needle and its dir if the needle is not cached
    if (!$needle) {
        my $dbh = $schema->storage->dbh;
        my $sth_needle_dir = $dbh->prepare(<<~'END_SQL');
            INSERT INTO needle_dirs (path, name)
                             VALUES (?,    ?)
              ON CONFLICT DO NOTHING RETURNING id
          END_SQL
        my $sth_needle = $dbh->prepare(<<~'END_SQL');
            INSERT INTO needles (dir_id, filename, last_updated, t_created, t_updated)
                         VALUES (?,      ?,        now(),        now(),     now())
              ON CONFLICT DO NOTHING RETURNING id
          END_SQL

        # determine canonical path
        my $real_file_path = realpath($filename);
        my $real_dir_path = realpath($needle_dir);
        my ($dir_path, $basename);
        if (index($real_file_path, $real_dir_path) != 0) {    # leave old behaviour as it is
            $dir_path = dirname($real_file_path);
            $basename = basename($real_file_path);
        }
        else {
            $dir_path = $real_dir_path;
            $basename = substr $real_file_path, length($real_dir_path) + 1, length($real_file_path);
        }

        # find/insert the needle dir and the needle itself
        my $dir_name = sprintf('%s-%s', $job->DISTRI, $job->VERSION);
        $sth_needle_dir->execute($dir_path, $dir_name);
        my ($dir_id) = $sth_needle_dir->fetchrow_array
          // $schema->resultset('NeedleDirs')->find({path => $dir_path})->id;
        $sth_needle->execute($dir_id, $basename);
        ($needle_id) = $sth_needle->fetchrow_array;
        $needle = $schema->resultset('Needles')->find($needle_id // {dir_id => $dir_id, filename => $basename});
    }

    # update last seen/match
    # note: It is not impossible that two instances update this information independently of each other, but we
    #       don't mind the *exact* last module as long as it is alive around the same time.
    my $module_id = $module->id;
    my $now;
    if (($needle->last_seen_module_id // 0) < $module->id) {
        $needle->last_seen_module_id($module->id);
        $needle->last_seen_time($now //= now());
    }

    if ($matched && ($needle->last_matched_module_id // 0) < $module->id) {
        $needle->last_matched_module_id($module->id);
        $needle->last_matched_time($now //= now());
    }

    # update whether file present if a new needle was created
    $needle->check_file if $needle_id;

    # update the needle in cache or in storage (with cache the caller needs to update the needle in storage)
    $needle_cache ? $needle_cache->{$filename} = $needle : $needle->update;
    $guard->commit;
    return $needle;
}

sub name ($self) {
    my ($name, $dir, $extension) = fileparse($self->filename, qw(.json));
    return $name;
}

sub path ($self) {
    return $self->directory->path . '/' . $self->filename;
}

sub remove ($self, $user) {
    my $fname = $self->path;
    my $screenshot = $fname =~ s/.json$/.png/r;
    my $app = OpenQA::App->singleton;
    $app->log->debug("Remove needle $fname and $screenshot");

    my $git = OpenQA::Git->new({app => $app, dir => $self->directory->path, user => $user});
    if ($git->autocommit_enabled) {
        my $directory = $self->directory;
        my $error = $git->commit(
            {
                rm => [$fname, $screenshot],
                message => sprintf('Remove %s/%s', $directory->name, $self->filename),
            });
        return $error if $error;
    }
    else {
        my @error_files;
        unlink($fname) or push(@error_files, $fname);
        unlink($screenshot) or push(@error_files, $screenshot);
        if (@error_files) {
            my $error = 'Unable to delete ' . join(' and ', @error_files);
            $app->log->debug($error);
            return $error;
        }
    }
    $self->check_file;
    $self->update;
    return 0;
}

sub check_file ($self) { $self->file_present(-e $self->path ? 1 : 0) }

sub to_json ($self) {
    my $needle_id = $self->id;
    return {
        id => $needle_id,
        name => $self->name,
        directory => $self->directory->name,
        tags => $self->tags,
        t_created => $self->t_created->datetime() . 'Z',
        t_updated => $self->t_updated->datetime() . 'Z',
        json_path => "/needles/$needle_id/json",
        image_path => "/needles/$needle_id/image",
    };
}

my $fmt = '%Y-%m-%dT%H:%M:%S%z';    # with offset
sub last_seen_time_fmt ($self) {
    $self->last_seen_time ? $self->last_seen_time->strftime($fmt) : 'never';
}
sub last_matched_time_fmt ($self) {
    $self->last_matched_time ? $self->last_matched_time->strftime($fmt) : 'never';
}

1;
