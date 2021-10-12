# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::ServerSideDataTable;

use strict;
use warnings;

sub render_response {
    my (%args) = @_;
    # mandatory parameter
    my $controller = $args{controller};
    my $resultset_name = $args{resultset};
    my $columns = $args{columns};
    my $prepare_data_function = $args{prepare_data_function};
    # optional parameter
    my $initial_conds = $args{initial_conds} // [];
    my $filter_conds = $args{filter_conds};
    my $params = $args{additional_params} // {};

    my $resultset = $controller->schema->resultset($resultset_name);

    # determine total count
    my $total_count
      = $initial_conds
      ? $resultset->search({-and => $initial_conds})->count
      : $resultset->count;

    # determine filtered count
    my $filtered_count;
    if ($filter_conds) {
        push(@$filter_conds, @$initial_conds);
        $filtered_count = $resultset->search({-and => $filter_conds}, $params)->count;
    }
    else {
        $filter_conds = $initial_conds;
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
            recordsTotal => $total_count,
            recordsFiltered => $filtered_count,
            data => $data,
        });
}

1;
