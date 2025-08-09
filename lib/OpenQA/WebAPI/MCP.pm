# Copyright 2025 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::MCP;
use Mojo::Base 'MCP::Server', -signatures;

sub new ($class) {
    my $self = $class->SUPER::new;

    $self->name('openQA');
    $self->version('1.0.0');

    $self->tool(
        name => 'current_user',
        description => 'Get the openQA name and id of the current user',
        code => \&tool_current_user
    );

    return $self;
}

sub tool_current_user ($tool, $args) {
    my $user = _get_user($tool);
    return "name: @{[$user->name]}, id: @{[$user->id]}";
}

sub _get_user ($tool) {
    return $tool->context->{controller}->stash->{current_user}{user};
}

1;
