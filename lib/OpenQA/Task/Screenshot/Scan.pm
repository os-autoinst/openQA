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

package OpenQA::Task::Screenshot::Scan;
use Mojo::Base 'Mojolicious::Plugin';

use OpenQA::Utils;
use Mojo::URL;
use File::Spec::Functions 'catfile';
use File::Basename qw(basename dirname);
use OpenQA::Utils qw(log_debug log_warning log_fatal);

sub register {
    my ($self, $app) = @_;
    $app->minion->add_task(scan_images       => sub { _scan_images($app, @_) });
    $app->minion->add_task(scan_images_links => sub { _scan_images_links($app, @_) });
}

sub _list_images_subdir {
    my ($app, $prefix, $dir) = @_;


    my $subdir = catfile($OpenQA::Utils::imagesdir, $prefix, $dir);
    my $dh;

    log_fatal "Can't open $subdir: $!" unless opendir($dh, $subdir);

    my @ret;
    for my $file (readdir $dh) {
        my $fn = catfile($subdir, $file);
        if ($fn =~ /.png$/ && -f $fn) {
            push(@ret, catfile($prefix, $dir, $file));
        }
    }
    closedir($dh);
    return \@ret,;
}

# gru task to scan XXX subdirectory
sub _scan_images {
    my ($app, $job, $args) = @_;

    # prevent multiple scan_images* tasks to run in parallel
    return $job->retry({delay => 30})
      unless my $guard = $app->minion->guard('limit_scan_images_task', 3600);

    return unless $args->{prefix};
    my $dh;
    my $prefixdir = catfile($OpenQA::Utils::imagesdir, $args->{prefix});

    log_fatal "Can't open $args->{prefix} in $OpenQA::Utils::imagesdir: $!" unless opendir($dh, $prefixdir);

    my @files;
    my $now = DateTime->now;
    for my $file (readdir $dh) {
        if ($file !~ /^\./ && -d "$prefixdir/$file") {
            push(@files, map { [$_, $now] } @{_list_images_subdir($app, $args->{prefix}, $file)});
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
sub _scan_images_links {
    my ($app, $job, $args) = @_;

    # prevent multiple scan_images* tasks to run in parallel
    return $job->retry({delay => 30})
      unless my $guard = $app->minion->guard('limit_scan_images_task', 3600);

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
        for my $file (readdir $dh) {
            my $fn = catfile($rd, $file);
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
