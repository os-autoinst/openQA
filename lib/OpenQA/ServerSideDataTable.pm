# Copyright (C) 2017 SUSE Linux LLC
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

package OpenQA::ServerSideDataTable;
use Scalar::Util;
use strict;

sub render_response {
    my (%args) = @_;
    # mandatory parameter
    my $controller            = $args{controller};
    my $resultset             = $args{resultset};
    my $columns               = $args{columns};
    my $prepare_data_function = $args{prepare_data_function};
    # optional parameter
    my $custom_query  = $args{custom_query};
    my $initial_conds = $args{initial_conds} // [];
    my $filter_conds  = $args{filter_conds};
    my $params        = $args{additional_params} // {};

    $resultset = Scalar::Util::blessed($resultset) ? $resultset : $controller->db->resultset($resultset);

    # determine total count
    my $total_count
      = $initial_conds ?
      $resultset->search({-and => $initial_conds})->count
      : $resultset->count;

    # determine filtered count
    my $filtered_count;
    if ($filter_conds) {
        push(@$filter_conds, @$initial_conds);
        $filtered_count = $resultset->search({-and => $filter_conds}, $params)->count;
    }
    else {
        $filter_conds   = $initial_conds;
        $filtered_count = $total_count;
    }

    # add parameter for sort order
    my @order_by_params;
    my $index = 0;
    while (1) {
        my $column_index = $controller->param("order[$index][column]") // @$columns;
        my $column_order = $controller->param("order[$index][dir]");
        last unless $column_index < @$columns && grep { $column_order eq $_ } qw(asc desc);
        push(@order_by_params, {'-' . $column_order => $columns->[$column_index]});
        ++$index;
    }
    $params->{order_by} = \@order_by_params if @order_by_params;

    # add parameter for paging
    my $first_row = $controller->param('start');
    $params->{offset} = $first_row if $first_row;
    my $row_limit = $controller->param('length');
    $params->{rows} = $row_limit if $row_limit;

    # get results and compute data for JSON serialization using
    # provided function
    my $results = $resultset->search({-and => $filter_conds}, $params);
    my $data = $prepare_data_function->($results);

    $controller->render(
        json => {
            recordsTotal    => $total_count,
            recordsFiltered => $filtered_count,
            data            => $data,
            rows            => $params->{rows},
        });
}

1;

# vim: set sw=4 et:
