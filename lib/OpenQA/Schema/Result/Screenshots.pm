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
use base qw(DBIx::Class::Core);
use strict;
use File::Spec::Functions qw(catfile);
use OpenQA::Utils qw(log_debug log_warning);

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

sub _list_images_subdir {
    my ($app, $prefix, $dir) = @_;
    log_debug "reading $prefix/$dir";
    my $subdir = catfile($OpenQA::Utils::imagesdir, $prefix, $dir);
    my $dh;
    if (!opendir($dh, $subdir)) {
        log_warning "Can't open $subdir: $!";
        return;
    }
    my @ret;
    while (readdir $dh) {
        my $fn = catfile($subdir, $_);
        if (-f $fn) {
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
    push(@files, [qw(filename t_created)]);
    while (readdir $dh) {
        if ($_ !~ /^\./ && -d "$prefixdir/$_") {
            push(@files, map { [$_, $now] } @{_list_images_subdir($app, $args->{prefix}, $_)});
        }
    }
    closedir($dh);
    $app->db->resultset('Screenshots')->populate(\@files);
    return;
}

1;
