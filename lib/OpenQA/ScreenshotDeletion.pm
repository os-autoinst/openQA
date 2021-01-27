# Copyright (C) 2020 SUSE LLC
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

package OpenQA::ScreenshotDeletion;
use Mojo::Base -base;

use File::Basename qw(basename dirname);
use File::Spec::Functions qw(catfile);
use OpenQA::Log qw(log_debug);
use OpenQA::Utils qw(imagesdir);

sub new {
    my ($class, %args) = @_;

    my $self = $class->SUPER::new;
    $self->{_deletion_query} = $args{dbh}->prepare('DELETE FROM screenshots WHERE id = ?');
    $self->{_imagesdir}      = $args{imagesdir} // imagesdir();
    $self->{_deleted_size}   = $args{deleted_size};
    return $self;
}

sub delete_screenshot {
    my ($self, $screenshot_id, $screenshot_filename) = @_;

    my $screenshot_path = catfile($self->{_imagesdir}, $screenshot_filename);
    my $thumb_path      = catfile(dirname($screenshot_path), '.thumbs', basename($screenshot_filename));

    # delete screenshot in database first
    # note: This might fail due to foreign key violation because a new screenshot link might
    #       have just been created. In this case the screenshot should not be deleted in the
    #       database or the file system.
    return undef unless eval { $self->{_deletion_query}->execute($screenshot_id); 1 };

    # keep track of the deleted size
    my ($deleted_size, $screenshot_size, $thumb_size) = $self->{_deleted_size};
    if ($deleted_size) {
        $screenshot_size = -s $screenshot_path;
        $thumb_size      = -s $thumb_path;
    }

    unless (unlink($screenshot_path, $thumb_path) == 2) {
        if (-e $screenshot_path) {
            log_debug qq{Can't remove screenshot "$screenshot_path"};
        }
        elsif ($deleted_size && $screenshot_size) {
            $$deleted_size += $screenshot_size;
        }
        if (-e $thumb_path) {
            log_debug qq{Can't remove thumbnail "$thumb_path"};
        }
        elsif ($deleted_size && $thumb_size) {
            $$deleted_size += $thumb_size;
        }
    }
    elsif ($deleted_size) {
        $$deleted_size += $screenshot_size if $screenshot_size;
        $$deleted_size += $thumb_size      if $thumb_size;
    }
}

1;
