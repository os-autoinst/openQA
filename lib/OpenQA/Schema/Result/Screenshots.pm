# Copyright (C) 2016 SUSE LLC
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

package OpenQA::Schema::Result::Screenshots;
use base 'DBIx::Class::Core';
use strict;
use File::Spec::Functions 'catfile';
use File::Basename qw(basename dirname);
use OpenQA::Utils qw(log_debug log_warning);
use Try::Tiny;

__PACKAGE__->table('screenshots');
__PACKAGE__->load_components(qw(InflateColumn::DateTime));

__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    filename => {
        data_type   => 'text',
        is_nullable => 0,
    },
    # we don't care for t_updated, so just add t_created
    t_created => {
        data_type   => 'timestamp',
        is_nullable => 0,
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(filename)]);
__PACKAGE__->has_many(
    links => 'OpenQA::Schema::Result::ScreenshotLinks',
    'screenshot_id',
    {cascade_delete => 0});
__PACKAGE__->has_many(
    links_outer => 'OpenQA::Schema::Result::ScreenshotLinks',
    'screenshot_id',
    {join_type => 'left outer', cascade_delete => 0});

# overload to remove on disk too
sub delete {
    my ($self) = @_;

    # first try to delete, if this fails due to foreign key violation, do not
    # delete the file. It's possible that some other worker uploaded a symlink
    # to this file while we're trying to delete the single job referencing it
    my $ret = $self->SUPER::delete;

    log_debug("removing screenshot " . $self->filename);
    if (!unlink(catfile($OpenQA::Utils::imagesdir, $self->filename))) {
        log_warning "can't remove " . $self->filename;
    }
    my $thumb = catfile($OpenQA::Utils::imagesdir, dirname($self->filename), '.thumbs', basename($self->filename));
    if (!unlink($thumb)) {
        log_warning "can't remove $thumb";
    }
    return $ret;
}

sub _list_images_subdir {
    my ($app, $prefix, $dir) = @_;
    my $subdir = catfile($OpenQA::Utils::imagesdir, $prefix, $dir);
    my $dh;
    if (!opendir($dh, $subdir)) {
        log_warning "Can't open $subdir: $!";
        return;
    }
    my @ret;
    while (readdir $dh) {
        my $fn = catfile($subdir, $_);
        if ($fn =~ /.png$/ && -f $fn) {
            push(@ret, catfile($prefix, $dir, $_));
        }
    }
    closedir($dh);
    return \@ret,;
}

# gru task to scan XXX subdirectory
sub scan_images {
    my ($app, $args) = @_;

    return unless $args->{prefix};
    my $dh;
    my $prefixdir = catfile($OpenQA::Utils::imagesdir, $args->{prefix});
    if (!opendir($dh, $prefixdir)) {
        log_warning "Can't open $args->{prefix} in $OpenQA::Utils::imagesdir: $!";
        return;
    }
    my @files;
    my $now = DateTime->now;
    while (readdir $dh) {
        if ($_ !~ /^\./ && -d "$prefixdir/$_") {
            push(@files, map { [$_, $now] } @{_list_images_subdir($app, $args->{prefix}, $_)});
        }
    }
    closedir($dh);
    while (@files) {
        my @part = splice @files, 0, 100;
        try {
            unshift(@part, [qw(filename t_created)]);
            $app->db->resultset('Screenshots')->populate(\@part);
            @part = ();
        }
        catch { };
        # if populate fails, resort to insert - this runs as GRU task and some images
        # might already be in, but the filename is unique
        shift @part;    # columns
        for my $row (@part) {
            try {
                $app->db->resultset('Screenshots')->create({filename => $row->[0], t_created => $row->[1]});
            }
            catch {
                my $error = shift;
                log_debug "Inserting $row->[0] failed: $error";
            };
        }
    }
    return;
}

# gru task - scan testresults and add them to Screenshotlinks
sub scan_images_links {
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
        my $dh;
        my $rd = $job->result_dir;
        next unless $rd && -d $rd;
        if (!opendir($dh, $rd)) {
            log_warning "Can't open test result of " . $job->id;
            next;
        }
        my @imgs;
        while (readdir $dh) {
            my $fn = catfile($rd, $_);
            if ($fn =~ /\.png$/ && -l $fn) {
                my $lt = readlink($fn);
                $lt =~ s,.*/images/,,;
                push(@imgs, $lt);
            }
        }
        closedir($dh);
        OpenQA::Schema::Result::ScreenshotLinks::populate_images_to_job($schema, \@imgs, $job->id);
    }

    # last job is going to delete everything left
    if (!$args->{min_job}) {
        # remove migration marker. After this point jobs can freely delete
        # screenshots
        unlink(catfile($OpenQA::Utils::imagesdir, 'migration_marker'));

        my $fns = $schema->resultset('Screenshots')->search_rs(
            {},
            {
                join     => 'links_outer',
                group_by => 'me.id',
                having   => \['COUNT(links_outer.job_id) = 0']});
        while (my $screenshot = $fns->next) {
            $screenshot->delete;
        }
    }
}

1;
