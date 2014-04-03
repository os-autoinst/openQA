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

sub index {
    my $self = shift;
    my @products = $self->db->resultset("Products")->search(undef, {order_by => 'name'});

    $self->stash('error', undef);
    $self->stash('products', \@products);
    $self->render('admin/product/index');
}

sub create {
    my $self = shift;
    my $error;
    my $validation = $self->validation;
    $validation->required('name');
    $validation->required('distri');
    $validation->required('arch');
    $validation->required('flavor');
    $validation->required('variables')->like(qr/^(\w+=[ \,\.\-\w]+;?)+$/);
    if ($validation->has_error) {
        $error = "wrong parameters";
        if ($validation->has_error('variables')) {
            $error = $error.' Variables should contain a list of assignations delimited by semicolons.';
        }
    }
    else {
        eval { $self->db->resultset("Products")->create({name => $self->param('name'),distri => $self->param('distri'),arch => $self->param('arch'),variables => $self->param('variables'),flavor => $self->param('flavor')}) };
        $error = $@;
    }
    if ($error) {
        my @products = $self->db->resultset("Products")->search(undef, {order_by => 'name'});
        $self->stash('error', "Error adding the product: $error");
        $self->stash('products', \@products);
        $self->render('admin/product/index');
    }
    else {
        $self->flash(info => 'Product '.$self->param('name').' added');
        $self->redirect_to($self->url_for('admin_products'));
    }
}

sub destroy {
    my $self = shift;
    my $products = $self->db->resultset('Products');

    if ($products->search({id => $self->param('productid')})->delete_all) {
        $self->flash(info => 'Product deleted');
    }
    else {
        $self->flash(error => 'Failed to delete product');
    }
    $self->redirect_to($self->url_for('admin_products'));
}

1;
