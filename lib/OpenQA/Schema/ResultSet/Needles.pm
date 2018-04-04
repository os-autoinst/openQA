# Copyright (C) 2018 LLC
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

package OpenQA::Schema::ResultSet::Needles;
use strict;
use base 'DBIx::Class::ResultSet';
use OpenQA::Schema::Result::Needles;
use OpenQA::Schema::Result::NeedleDirs;

# updates needle information with data from needle editor
sub update_needle_from_editor {
    my ($self, $needledir, $needlename, $needlejson, $job) = @_;

    # create containing dir if not present yet
    my $dir = $self->result_source->schema->resultset('NeedleDirs')->find_or_new(
        {
            path => $needledir
        });
    if (!$dir->in_storage) {
        $dir->set_name_from_job($job);
        $dir->insert;
    }

    # create/update the needle
    my $needle = $self->find_or_create(
        {
            filename => "$needlename.json",
            dir_id   => $dir->id,
        },
        {
            key => 'needles_dir_id_filename'
        });
    $needle->update(
        {
            tags => $needlejson->{tags},
        });
    return $needle;
}

sub new_needles_since {
    my ($self, $since, $tags) = @_;

    my @new_needle_conds;
    for my $tag (@$tags) {
        push(@new_needle_conds, \["? = ANY (tags)", $tag]);
    }

    return $self->search(
        {
            t_created => {'>' => $since},
            -or       => \@new_needle_conds,
        },
        {
            order_by => {-desc => 'id'},
            rows     => 5,
        });
}

1;
