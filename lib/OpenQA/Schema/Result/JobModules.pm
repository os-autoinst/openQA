# Copyright (C) 2015-2016 SUSE LLC
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

package OpenQA::Schema::Result::JobModules;
use base qw/DBIx::Class::Core/;

use strict;
use db_helpers;
use OpenQA::Scheduler::Scheduler;
use OpenQA::Schema::Result::Jobs;
use JSON ();
use File::Basename qw/dirname basename/;
use File::Path qw/remove_tree/;
use Cwd qw/abs_path/;
use Try::Tiny;
use 5.012;    # so readdir assigns to $_ in a lone while test

__PACKAGE__->table('job_modules');
__PACKAGE__->load_components(qw/InflateColumn::DateTime Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    job_id => {
        data_type      => 'integer',
        is_foreign_key => 1,
    },
    name => {
        data_type => 'text',
    },
    script => {
        data_type => 'text',
    },
    category => {
        data_type => 'text',
    },
    # flags - not using a bit field and not using a join table
    # to simplify code. In case we get a much bigger database, we
    # might reconsider
    milestone => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0
    },
    important => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0
    },
    fatal => {
        data_type     => 'integer',
        is_nullable   => 0,
        default_value => 0
    },
    result => {
        data_type     => 'varchar',
        default_value => OpenQA::Schema::Result::Jobs::NONE,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(
    "job",
    "OpenQA::Schema::Result::Jobs",
    {'foreign.id' => "self.job_id"},
    {
        is_deferrable => 1,
        join_type     => "LEFT",
        on_update     => "CASCADE",
    },
);
__PACKAGE__->has_many(needle_hits => 'OpenQA::Schema::Result::JobModuleNeedles', 'job_module_id');

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'idx_job_modules_result', fields => ['result']);
}

# overload to straighten out needle references
sub delete {
    my ($self) = @_;

    # those are just there for tracking
    $self->needle_hits->delete;

    my $schema = $self->result_source->schema;
    my @ors;
    push(@ors, {last_seen_module_id    => $self->id});
    push(@ors, {first_seen_module_id   => $self->id});
    push(@ors, {last_matched_module_id => $self->id});

    my $needles = $schema->resultset('Needles')->search({-or => \@ors});
    while (my $needle = $needles->next) {
        $needle->recalculate_matches;
    }
    return $self->SUPER::delete;
}

sub details {
    my ($self) = @_;

    my $dir = $self->job->result_dir();
    return unless $dir;
    my $fn = "$dir/details-" . $self->name . ".json";
    OpenQA::Utils::log_debug "reading $fn";
    open(my $fh, "<", $fn) || return [];
    local $/;
    my $ret;
    # decode_json dies if JSON is malformed, so handle that
    try {
        $ret = JSON::decode_json(<$fh>);
    }
    catch {
        OpenQA::Utils::log_debug "malformed JSON file $fn";
        $ret = [];
    }
    finally {
        close($fh);
    };
    for my $img (@$ret) {
        next unless $img->{screenshot};
        my $link = abs_path($dir . "/" . $img->{screenshot});
        next unless $link;
        my $base = basename($link);
        my $dir  = dirname($link);
        # if linking into images, translate it into md5 lookup
        if ($dir =~ m,/images/,) {
            $dir =~ s,^.*/images/,,;
            $img->{md5_dirname}  = $dir;
            $img->{md5_basename} = $base;
        }
    }

    return $ret;
}

# gru task to migrate from XX/REST to XXX/YY/REST
sub migrate_images {
    my ($app, $args) = @_;

    return unless $args->{prefix};
    my $dh;
    my $prefixdir = join('/', $OpenQA::Utils::imagesdir, $args->{prefix});
    if (!opendir($dh, $prefixdir)) {
        OpenQA::Utils::log_warning "Can't open $args->{prefix} in $OpenQA::Utils::imagesdir: $!";
        return;
    }
    OpenQA::Utils::log_debug "moving files in $prefixdir";
    while (readdir $dh) {
        # only rename .pngs not symlinked
        if (-f "$prefixdir/$_" && !-l "$prefixdir/$_" && m/^(.*)\.png/) {
            my $old = $_;
            my $md5 = $args->{prefix} . $1;
            my ($img, $thumb) = OpenQA::Utils::image_md5_filename($md5);

            my $md5dir = dirname($img);
            # will throw if there is a problem - but we can't ignore errors in the new
            # paths
            File::Path::make_path($md5dir);
            File::Path::make_path("$md5dir/.thumbs");
            rename("$prefixdir/$old", $img);
            # symlink as the testresults symlink here
            symlink($img, "$prefixdir/$old");
            rename("$prefixdir/.thumbs/$old", $thumb);
            symlink($thumb, "$prefixdir/.thumbs/$old");
        }
    }
    closedir($dh);
}

sub _relink_dir {
    my ($dir) = @_;
    my $dh;
    if (!$dir || !opendir($dh, $dir)) {
        # job has no results - so what
        return;
    }
    OpenQA::Utils::log_debug "relinking images in $dir";
    while (readdir $dh) {
        # only relink symlinked .pngs
        if (-l "$dir/$_" && m/^(.*)\.png/) {
            my $old     = "$dir/$_";
            my $md5path = abs_path($old);
            # skip stale symlinks
            next unless $md5path;
            my $md5dir = dirname($md5path);
            File::Path::make_path($md5dir);
            rename($old, "$old.old");
            # symlink as the testresults symlink here
            if (symlink($md5path, $old)) {
                unlink("$old.old");
            }
        }
    }
    closedir($dh);
    return 1;
}

# gru task - run after the above is done and relink the testresult images
sub relink_testresults {
    my ($app, $args) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    my $jobs   = $schema->resultset("Jobs")->search(
        {
            id => {
                '<=' => $args->{max_job},
                '>'  => $args->{min_job}}
        },
        {order_by => ['id DESC']});
    while (my $job = $jobs->next) {
        if (_relink_dir($job->result_dir)) {
            _relink_dir($job->result_dir . "/.thumbs");
        }
    }
}

# last gru task in the image migration
sub rm_compat_symlinks {
    my ($app, $args) = @_;

    opendir(my $dh, $OpenQA::Utils::imagesdir) || die "Can't open /images: $!";
    while (readdir $dh) {
        if (m/^([^.].)$/) {
            remove_tree("$OpenQA::Utils::imagesdir/$_");
        }
    }
    closedir $dh;
}

sub job_module {
    my ($job, $name) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    return $schema->resultset("JobModules")->search({job_id => $job->id, name => $name})->first;
}

sub job_modules($) {
    my ($job) = @_;

    my $schema = OpenQA::Scheduler::Scheduler::schema();
    return $schema->resultset("JobModules")->search({job_id => $job->id}, {order_by => 'id'})->all;
}

sub job_module_stats($) {
    my ($jobs) = @_;

    my $result_stat = {};

    my $schema = OpenQA::Scheduler::Scheduler::schema();

    my $ids;

    if (ref($jobs) ne 'ARRAY') {
        my @ids;
        while (my $j = $jobs->next) { push(@ids, $j->id); }
        $jobs->reset;
        $ids = \@ids;
    }
    else {
        $ids = $jobs;
    }

    for my $id (@$ids) {
        $result_stat->{$id} = {passed => 0, failed => 0, softfailed => 0, none => 0};
    }

    my $query = $schema->resultset("JobModules")->search(
        {job_id => {in => $ids}},
        {
            select   => ['job_id', 'result', {count => 'id'}],
            as       => [qw/job_id result count/],
            group_by => [qw/job_id result/]});

    while (my $line = $query->next) {
        $result_stat->{$line->job_id}->{$line->result} = $line->get_column('count');
    }

    return $result_stat;
}

sub update_result($) {
    my ($self, $r) = @_;

    my $result = $r->{result};

    $result ||= 'none';
    $result =~ s,fail,failed,;
    $result =~ s,^na,none,;
    $result =~ s,^ok,passed,;
    $result =~ s,^unk,none,;
    $result =~ s,^skip,skipped,;
    if ($r->{dents} && $result eq 'passed') {
        $result = 'softfailed';
    }
    $self->update(
        {
            result => $result,
        });
}

# if you give a needle_cache, make sure to call
# OpenQA::Schema::Result::Needles::update_needle_cache
sub store_needle_infos($;$) {
    my ($self, $details, $needle_cache) = @_;

    my $schema = $self->result_source->schema;

    # we often see the same needles in the same test, so avoid duplicated work
    my %hash;
    if (!$needle_cache) {
        # if this is run outside of a global context, we need to avoid duplicates ourself
        $schema->resultset('JobModuleNeedles')->search({job_module_id => $self->id})->delete;
        $needle_cache = \%hash;
    }

    my %needles;

    for my $detail (@{$details}) {
        if ($detail->{needle}) {
            my $nfn = $detail->{json};
            my $needle = OpenQA::Schema::Result::Needles::update_needle($nfn, $self, 1, $needle_cache);
            $needles{$needle->id} ||= 1;
        }
        for my $needle (@{$detail->{needles} || []}) {
            my $nfn = $needle->{json};
            my $needle = OpenQA::Schema::Result::Needles::update_needle($nfn, $self, 0, $needle_cache);
            # failing needles are more interesting than succeeding, so ignore previous values
            $needles{$needle->id} = -1;
        }
    }

    my @val;
    for my $nid (keys %needles) {
        push(@val, {job_module_id => $self->id, needle_id => $nid, matched => $needles{$nid} > 1 ? 1 : 0});
    }
    $schema->resultset('JobModuleNeedles')->populate(\@val);

    # if it's someone else's cache, he has to be aware
    OpenQA::Schema::Result::Needles::update_needle_cache(\%hash);
}

sub _save_details_screenshot {
    my ($self, $screenshot, $existent_md5, $cleanup) = @_;

    my ($full, $thumb) = OpenQA::Utils::image_md5_filename($screenshot->{md5});
    if (-e $full) {    # mark existent
        push(@$existent_md5, $screenshot->{md5});
    }
    if ($cleanup) {
        # interactive mode, recreate the symbolic link of screenshot if it was changed
        my $full_link  = readlink($self->job->result_dir . "/" . $screenshot->{name})         || '';
        my $thumb_link = readlink($self->job->result_dir . "/.thumbs/" . $screenshot->{name}) || '';
        if ($full ne $full_link) {
            OpenQA::Utils::log_debug "cleaning up " . $self->job->result_dir . "/" . $screenshot->{name};
            unlink($self->job->result_dir . "/" . $screenshot->{name});
        }
        if ($thumb ne $thumb_link) {
            OpenQA::Utils::log_debug "cleaning up " . $self->job->result_dir . "/.thumbs/" . $screenshot->{name};
            unlink($self->job->result_dir . "/.thumbs/" . $screenshot->{name});
        }
    }
    symlink($full,  $self->job->result_dir . "/" . $screenshot->{name});
    symlink($thumb, $self->job->result_dir . "/.thumbs/" . $screenshot->{name});
    return $screenshot->{name};
}

sub save_details {
    my ($self, $details, $cleanup) = @_;
    my $existent_md5 = [];
    my @dbpaths;
    my $schema = $self->result_source->schema;
    for my $d (@$details) {
        # avoid creating symlinks for text results
        if ($d->{screenshot}) {
            # save the database entry for the screenshot first
            push(@dbpaths, OpenQA::Utils::image_md5_filename($d->{screenshot}->{md5}, 1));
            # create possibly stale symlinks
            $d->{screenshot} = $self->_save_details_screenshot($d->{screenshot}, $existent_md5, $cleanup);
        }
    }
    OpenQA::Schema::Result::ScreenshotLinks::populate_images_to_job($schema, \@dbpaths, $self->job_id);

    $self->store_needle_infos($details);
    open(my $fh, ">", $self->job->result_dir . "/details-" . $self->name . ".json");
    $fh->print(JSON::encode_json($details));
    close($fh);
    return $existent_md5;
}

1;
# vim: set sw=4 et:
