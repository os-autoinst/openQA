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

package OpenQA::Admin::Product;
use Mojo::Base 'Mojolicious::Controller';

use base 'OpenQA::Admin::VariableHelpers';

sub index {
    my $self = shift;
    my @products = $self->db->resultset("Products")->search(undef, {order_by => 'name'});

    #    $self->stash('error', undef);
    $self->stash('products', \@products);

    my $rc = $self->db->resultset("ProductSettings")->search(undef, { columns => [qw/key/], distinct => 1 } );
    $self->stash('variables', [ sort map { $_->key } $rc->all() ]);

    $self->render('admin/product/index');
}

sub create {
    my $self = shift;
    my $error;
    my $validation = $self->validation;
    $validation->required('distri');
    $validation->required('version');
    $validation->required('arch');
    $validation->required('flavor');

    my $product;
    if ($validation->has_error) {
        $error = "wrong parameter: ";
        for my $k (qw/distri version arch flavor/) {
            $error .= $k if $validation->has_error($k);
        }
    }
    else {
        eval {
            $product = $self->db->resultset("Products")->create(
                {
                    distri => $self->param('distri'),
                    version => $self->param('version'),
                    arch => $self->param('arch'),
                    flavor => $self->param('flavor'),
                    name => '', # TODO: remove
                    variables => '', # TODO: remove
                }
            );
        };
        $error = $@;
        $error = "unexpected error: \$product undef" unless $error || $product;
    }
    if ($error) {
        $self->stash('error', "Error adding the product: $error");
        $self->app->log->error($error);
        return $self->index;
    }
    else {
        $self->flash(info => 'Product '.$product->name.' added');
        $self->redirect_to($self->url_for('admin_products'));
    }
}

sub add_variable {
    my $self = shift;
    $self->SUPER::add_variable('product', 'ProductSettings');
}

sub remove_variable {
    my $self = shift;
    $self->SUPER::remove_variable('product', 'ProductSettings');
}

sub destroy {
    my $self = shift;
    my $products = $self->db->resultset('Products');

    if ($products->search({id => $self->param('product_id')})->delete_all) {
        $self->flash(info => 'Product deleted');
    }
    else {
        $self->flash(error => 'Failed to delete product');
    }
    $self->redirect_to($self->url_for('admin_products'));
}

1;
