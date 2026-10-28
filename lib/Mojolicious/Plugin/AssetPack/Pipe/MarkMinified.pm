# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# NOTE: This is necessary because JavaScript::Minifier::XS is breaking
# the swagger-ui-bundle. It chops off everything after `://` for this code:
#   try{const s=`https://base${String(Math.random()).slice(2)}`,
# Also, the bundle is already minified, so it is not needed here.
# https://github.com/bleargh45/JavaScript-Minifier-XS/issues/14

package Mojolicious::Plugin::AssetPack::Pipe::MarkMinified;
use Mojo::Base 'Mojolicious::Plugin::AssetPack::Pipe', -signatures;

sub process ($self, $assets) {
    $assets->each(
        sub ($asset, $index) {
            $asset->minified(1) if $asset->url =~ m/swagger-ui.*js/;
        });
}

1;
