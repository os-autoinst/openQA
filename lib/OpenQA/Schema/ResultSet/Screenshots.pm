# Copyright (C) 2019 SUSE LLC
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

package OpenQA::Schema::ResultSet::Screenshots;

use strict;
use warnings;

use base 'DBIx::Class::ResultSet';

use DateTime;
use OpenQA::Utils 'log_debug';
use Try::Tiny;

sub populate_images_to_job {
    my ($self, $imgs, $job_id) = @_;

    # insert the symlinks into the DB
    my %ids;
    my $now = DateTime->now;
    for my $img (@$imgs) {
        log_debug "creating $img";
        try {
            $ids{$img} = $self->create({filename => $img, t_created => $now})->id;
        }
        catch {
            my $err = $_;
            die $err
              unless $err =~ /duplicate key value violates unique constraint "screenshots_filename"/;
            $ids{$img} = $self->find({filename => $img})->id;
        };
    }
    my @data = map { [$_, $job_id] } values %ids;
    $self->result_source->schema->resultset('ScreenshotLinks')->populate([[qw(screenshot_id job_id)], @data]);
}

1;
