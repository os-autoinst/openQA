# Copyright (C) 2014 SUSE Linux Products GmbH
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

package OpenQA::Schema::Result::Assets;
use base qw/DBIx::Class::Core/;

use db_helpers;

our %types = map { $_ => 1 } qw/iso repo hdd/;

__PACKAGE__->table('assets');
__PACKAGE__->load_components(qw/Timestamps/);
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    type => {
        data_type => 'text',
    },
    name => {
        data_type => 'text',
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw/type name/]);
__PACKAGE__->has_many(jobs_assets => 'OpenQA::Schema::Result::JobsAssets', 'asset_id');
__PACKAGE__->many_to_many(jobs => 'jobs_assets', 'job');

sub limit_assets {
    my ($app) = @_;
    my $groups = $app->db->resultset('JobGroups')->search({},{ select => 'id' });
    my %keep;
    while (my $g = $groups->next) {
        my $sizelimit = 20 * 1024 * 1024 * 1024; # 20GB
        my $assets = $app->db->resultset('JobsAssets')->search(
            {
                job_id => { -in => $g->jobs->get_column('id')->as_query },
                'asset.type' => ['iso']
            },
            {
                join => 'asset',
                order_by => 'asset.t_created desc',
                select => [qw/asset.name asset.type asset.id/],
                as => [qw/asset_name asset_type asset_id/],
                distinct => 1
            }
        );
        while (my $a = $assets->next) {
            next if $a->get_column('asset_type') ne 'iso';
            my $file = sprintf("%s/%s/%s", $OpenQA::Utils::assetdir,$a->get_column('asset_type'),$a->get_column('asset_name'));
            my @st = stat($file);
            if (@st && $st[7] > 0) {
                $keep{$a->asset_id} = 1;
                $sizelimit -= $st[7];
            }
            # check after keeping - so we can be sure to keep at least one even if sizelimit too strict
            last if $sizelimit < 0;
        }
    }
    if (%keep) {
        my $assets = $app->db->resultset('Assets')->search({ id => { not_in => [ sort keys %keep ] }});
        while (my $a = $assets->next) {
            my $file = sprintf("%s/%s/%s", $OpenQA::Utils::assetdir,$a->type,$a->name);
            print "RM $file\n";
            unlink($file);
            $a->delete;
        }
    }
}

1;
