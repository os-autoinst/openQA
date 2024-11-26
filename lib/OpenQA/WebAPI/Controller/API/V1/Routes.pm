# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::WebAPI::Controller::API::V1::Routes;
use Mojo::Base 'Mojolicious::Controller', -signatures;

=pod

=head1 NAME

OpenQA::WebAPI::Controller::API::V1::Routes

=head1 SYNOPSIS

  use OpenQA::WebAPI::Controller::API::V1::Routes;

=head1 DESCRIPTION


=head1 METHODS

=over 4

=item list()

Lists all WebAPI routes

=back

=cut

sub list ($self) {
    my $routes = $self->app->routes->children;
    my %hash;
    _walk($_, \%hash, '') for @$routes;
    my @list;
    for my $route (sort keys %hash) {
        my $methods = $hash{$route};
        push @list, {path => $route, methods => [sort keys %$methods]};
    }
    $self->render(json => {routes => \@list});
}

sub _walk ($route, $hash, $path) {
    my $pattern = $route->pattern->unparsed || '';
    my $methods = $route->can('methods') ? $route->methods : $route->via;
    my $endpoint = "$path$pattern" || '/';
    $hash->{$endpoint}->{$_} = 1 for @{$methods || []};
    for my $child (@{$route->children || []}) {
        _walk($child, $hash, "$path$pattern");
    }
}

1;
