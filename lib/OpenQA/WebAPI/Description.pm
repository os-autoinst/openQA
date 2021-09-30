# Copyright 2012-2018 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Description;

use strict;
use warnings;

use OpenQA::Log 'log_warning';
use Mojo::File 'path';
use Pod::POM;
use Exporter 'import';

our $VERSION = sprintf "%d.%03d", q$Revision: 0.01 $ =~ /(\d+)/g;
our @EXPORT = qw(
  get_pod_from_controllers
  set_api_desc
);

# Global hash to store method's description
my %methods_description;

# Determine the controller modules being used by the API routes and parse the POD from the files.
# Extract the description of the methods and store them in the global HASH %methods_description
# by walking the POD tree from each controller module file

sub get_pod_from_controllers {
    # Object to get API descriptions from POD
    my $parser = Pod::POM->new or die "cannot create object: $!\n";
    my $tree;
    my %controllers;
    # Path where openQA is installed
    my $app = shift;
    my $code_base = $app->home;
    my $ctrlrpath = path($code_base)->child('lib', 'OpenQA', 'WebAPI', 'Controller', 'API', 'V1');

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
        $tree = $parser->parse_file($ctrlrpath->child($controllers{$ctrl})->to_string);
        unless ($tree) {
            log_warning("get_pod_from_controllers: could not parse file: ["
                  . $ctrlrpath->child($controllers{$ctrl})->to_string
                  . "] for POD. Error: ["
                  . $tree->error()
                  . "]");
            next;
        }
        _itemize($tree, $ctrl);
    }
}

# Assign API description in a HASH passed as a hashref for the controller#action's found in the
# passed API route. The API descriptions were collected in get_pod_from_controllers()

sub set_api_desc {
    my $api_description = shift;
    my $api_route = shift;

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

# Recurse into a Pod::POM object - ie, walk the tree - and extract the =item sections' name
# and description. Sets its findings into %methods_description

sub _itemize {
    my $node = shift;
    if (ref($node) !~ /^Pod::POM::Node/) {
        log_warning("_itemize() expected Pod::POM::Node::* arg. Got " . ref($node));
        return 0;    # Stop walking the tree
    }
    my $controller = shift;
    my $methodname = '';
    my $desc = '';

    foreach my $s ($node->content()) {
        my $type = $s->type();
        if ($type eq 'item') {
            $methodname = $s->title;
            $desc = $s->text;
            $methodname =~ s/\s+//g;
            $methodname =~ s/\(\)//;
            $desc =~ s/[\r\n]/ /g;
            my $key = $controller . '#' . $methodname;
            $methods_description{$key} = $desc;
        }
        elsif ($type =~ /^head/ or $type eq 'over') {
            _itemize($s, $controller);
        }
    }
}

1;
