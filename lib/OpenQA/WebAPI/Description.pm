# Copyright (C) 2012-2018 SUSE LLC
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
# You should have received a copy of the GNU General Public License

package OpenQA::WebAPI::Description;
use strict;

use OpenQA::Utils 'log_warning';
use Mojo::File 'path';
use Pod::Tree;

require Exporter;
our ($VERSION, @ISA, @EXPORT, @EXPORT_OK, %EXPORT_TAGS);
$VERSION = sprintf "%d.%03d", q$Revision: 0.01 $ =~ /(\d+)/g;
@ISA     = qw(Exporter);
@EXPORT  = qw(
  get_pod_from_controllers
  set_api_desc
);

# Global hash to store method's description
my %methods_description;
# Path where openQA is installed
my $OPENQA_CODEBASE = '/usr/share/openqa';

# Determine the controller modules being used by the API routes and parse the POD from the files.
# Extract the description of the methods and store them in the global HASH %methods_description
# by ->walk()ing the POD tree from each controller module file

sub get_pod_from_controllers {
    # Object to get API descriptions from POD
    my $tree = Pod::Tree->new or die "cannot create object: $!\n";
    my %controllers;
    my $ctrlrpath = path($OPENQA_CODEBASE)->child('lib', 'OpenQA', 'WebAPI', 'Controller', 'API', 'V1');

    # Review all routes to get controllers, and from there get the .pm filename to parse for POD
    foreach my $api_rt (@_) {
        next if (ref($api_rt) ne 'Mojolicious::Routes::Route');
        foreach my $rt (@{$api_rt->children}) {
            next unless ($rt->to->{controller});
            my $filename = ucfirst($rt->to->{controller});
            if ($filename =~ /_/) {
                $filename = join('', map(ucfirst, split(/_/, $filename)));
            }
            $filename .= '.pm';
            $controllers{$rt->to->{controller}} = $filename;
        }
    }

    # Parse API controller files for POD
    foreach my $ctrl (keys %controllers) {
        # Only attempt to load files that exist
        next unless (-e -f $ctrlrpath->child($controllers{$ctrl})->to_string);
        $tree->load_file($ctrlrpath->child($controllers{$ctrl})->to_string);
        if ($tree->loaded() and $tree->has_pod()) {
            $tree->get_root->set_filename($ctrl);
            $tree->walk(\&_itemize);
        }
    }
}

# Assign API description in a HASH passed as a hashref for the controller#action's found in the
# passed API route. The API descriptions were collected in get_pod_from_controllers()

sub set_api_desc {
    my $api_description = shift;
    my $api_route       = shift;

    if (ref($api_description) ne 'HASH') {
        log_warning("set_api_desc: expected HASH ref for api_descriptions. Got: " . ref($api_description));
        return;
    }

    if (ref($api_route) ne 'Mojolicious::Routes::Route') {
        log_warning("set_api_desc: expected Mojolicious::Routes::Route for api_routes. Got: " . ref($api_route));
        return;
    }

    foreach my $r (@{$api_route->children}) {
        next unless ($r->to->{controller} and $r->to->{action});
        my $key = $r->to->{controller} . '#' . $r->to->{action};
        $api_description->{$r->name} = $methods_description{$key} if (defined $methods_description{$key});
    }
}

# Support method to ->walk() a POD tree and extract the documentation for each =item

sub _itemize {
    my ($node) = @_;
    if (ref($node) ne 'Pod::Tree::Node') {
        log_warning("_itemize() expected Pod::Tree::Node arg. Got " . ref($node));
        return 0;    # Stop walking the tree
    }
    my $methodname = '';
    my $desc       = '';
    my $controller = $node->get_filename;
    if ($node->is_item()) {
        $methodname = _get_pod_text($node);
        $methodname =~ s/\s+//g;
        $methodname =~ s/\(\)//;
        my $siblings = $node->get_siblings();
        foreach my $i (@$siblings) {
            unless ($desc) {    # Only take first paragraph for the description
                $desc = $i->get_text()    if $i->is_text();
                $desc = _get_pod_text($i) if $i->is_ordinary();
            }
        }
        my $key = $controller . '#' . $methodname;
        $methods_description{$key} = $desc;
    }
    else {
        return 1;               # Keep walking the tree
    }
}

# Extract POD text for children's of item and ordinary nodes

sub _get_pod_text {
    my $node   = shift;
    my $retval = '';
    if (ref($node) ne 'Pod::Tree::Node') {
        log_warning("_get_pod_text() expected Pod::Tree::Node arg. Got " . ref($node));
    }
    else {
        my $argtype = $node->get_type();
        unless ($argtype eq 'item' or $argtype eq 'ordinary') {
            log_warning("_get_pod_test() Pod::Tree::Node arg should be of type item or ordinary. Got [$argtype]");
        }
        my $children = $node->get_children();
        if (defined $children->[0] and ref($children->[0]) eq 'Pod::Tree::Node') {
            if ($children->[0]->is_text) {
                $retval = $children->[0]->get_text();
                $retval =~ s/[\r\n]/ /g;
            }
            if ($children->[0]->is_sequence) {
                my $seqs = $children->[0]->get_children();
                if (defined $seqs->[0] and ref($seqs->[0]) eq 'Pod::Tree::Node' and $seqs->[0]->is_text) {
                    $retval = $seqs->[0]->get_text();
                }
            }
        }
    }
    return $retval;
}

1;
# vim: set sw=4 et:
