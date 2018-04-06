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

1;
