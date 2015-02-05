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

package OpenQA::Controller::Admin::JobTemplate;
use Mojo::Base 'Mojolicious::Controller';
use DateTime::Format::SQLite;

sub index {
    my $self = shift;
    my @products = $self->db->resultset("Products")->search(undef, {order_by => 'name'});
    my @machines = $self->db->resultset("Machines")->search(undef, {order_by => 'name'});
    my @suites = $self->db->resultset("TestSuites")->search(undef, {order_by => 'name'});
    # TODO: rethink the SQL in a more cross-database way
    my $concat;
    if ($self->db->dsn =~ /:Pg:/) {
        $concat = { string_agg => ['test_suite_id::text', "','"] };
    }
    else {
        $concat = { group_concat => 'test_suite_id' };
    }
    my $temps = $self->db->resultset("JobTemplates")->search(
        undef,
        {
            select => ['product_id', 'machine_id', $concat],
            as => [qw/product_id machine_id ids/],
            group_by => [qw/product_id machine_id/]
        }
    );

    my $templates = {};
    while (my $template = $temps->next)  {
        $templates->{$template->product_id}->{$template->machine_id} = $template->get_column('ids');
    }

    $self->stash('products', \@products);
    $self->stash('machines', \@machines);
    $self->stash('suites', \@suites);
    $self->stash('templates', $templates);

    $self->render('admin/job_template/index');
}

sub update {
    my $self = shift;
    my $products = $self->db->resultset("Products")->search(undef, {order_by => 'name'});
    my @machines = $self->db->resultset("Machines")->search(undef, {order_by => 'name'});
    my @suites = $self->db->resultset("TestSuites")->search(undef, {order_by => 'name'});

    while (my $product = $products->next) {
        for my $machine (@machines) {
            my $requested = $self->every_param('templates_'.$product->id.'_'.$machine->id);
            my %present = map { $_ => 1 } @$requested;
            for my $suite (@suites) {
                my $existing = $self->db->resultset("JobTemplates")->find(
                    {
                        product_id => $product->id,
                        machine_id => $machine->id,
                        test_suite_id => $suite->id
                    }
                );
                # If is present in DB but not in the request, delete it
                if ($existing && !$present{$suite->id}) {
                    $existing->delete;
                    # The other way around? create it
                }
                elsif (!$existing && $present{$suite->id}) {
                    $self->db->resultset("JobTemplates")->create(
                        {
                            product_id => $product->id,
                            machine_id => $machine->id,
                            test_suite_id => $suite->id
                        }
                    );
                }
            }
        }
    }

    $self->flash(info => 'Template matrix updated');
    $self->redirect_to(action => 'index');
}

1;
