# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Assets;
use Mojo::Base -strict, -signatures;

# This file contains helpers to setup handling of assets of the web UI.

use Mojolicious;
use Mojo::File qw(path);
use Mojo::Home;
use OpenQA::Plugin::Vite;

sub setup ($server) {
    # Initialize the Vite plugin which provides the 'asset' and 'vite' helpers
    $server->plugin('OpenQA::Plugin::Vite');
}

sub list ($server = Mojolicious->new(home => Mojo::Home->new('.'))) {
    # Stub for backward compatibility with 'make node_modules' or similar
    # In Vite, assets are built via 'npm run build' generating public/dist/
    say 'Vite assets are pre-compiled and served from public/dist/.';
}

1;
