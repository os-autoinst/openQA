# Copyright (C) 2018 SUSE LLC
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

package OpenQA::Task::Job::Modules;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;

use File::Basename qw(dirname basename);
use File::Path 'remove_tree';
use Cwd 'abs_path';

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(migrate_images     => sub { _migrate_images($app, @_) });
    $app->minion->add_task(relink_testresults => sub { _relink_testresults($app, @_) });
    $app->minion->add_task(rm_compat_symlinks => sub { _rm_compat_symlinks($app, @_) });
}

sub _migrate_images {
    my ($app, $job, $args) = @_;

    return unless $args->{prefix};
    my $dh;
    my $prefixdir = join('/', $OpenQA::Utils::imagesdir, $args->{prefix});

    OpenQA::Utils::log_fatal "Can't open $args->{prefix} in $OpenQA::Utils::imagesdir: $!"
      unless opendir($dh, $prefixdir);

    OpenQA::Utils::log_debug "moving files in $prefixdir";
    for my $file (readdir $dh) {
        # only rename .pngs not symlinked
        if (-f "$prefixdir/$file" && !-l "$prefixdir/$file" && $file =~ m/^(.*)\.png/) {
            my $old = $file;
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
    for my $file (readdir $dh) {
        # only relink symlinked .pngs
        if (-l "$dir/$file" && $file =~ m/^(.*)\.png/) {
            my $old     = "$dir/$file";
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
sub _relink_testresults {
    my ($app, $job, $args) = @_;

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
sub _rm_compat_symlinks {
    my ($app, $args) = @_;

    opendir(my $dh, $OpenQA::Utils::imagesdir) || die "Can't open /images: $!";
    for my $file (readdir $dh) {
        if ($file =~ m/^([^.].)$/) {
            remove_tree("$OpenQA::Utils::imagesdir/$file");
        }
    }
    closedir $dh;
}


1;
