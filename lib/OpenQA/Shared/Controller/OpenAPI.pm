# Copyright 2019 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Shared::Controller::OpenAPI;
use Mojo::Base 'Mojolicious::Controller', -signatures;
use Mojo::JSON qw(encode_json decode_json);

sub catchall ($c) {
    my $result = $c->validate_request;
    unless ($result->valid) {
        return $c->render(status => 400, json => {result => $result});
    }
    my $VALIDATE = $c->stash('openapi');
    my $path_captures = $VALIDATE->{path_captures};
    $c->stash($_, $path_captures->{$_}) for keys %$path_captures;
    my $op = $VALIDATE->{operation_id};
    if ($op =~ s/^operation_(jobs|groups)_//) {
        return $c->$op();
    }
    die "Should not happen";
}

1;
