# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Assets;
use Mojo::Base -strict, -signatures;

# This file contains helpers to setup handling of assets of the web UI. The list function is used at install-time.

use Mojolicious;
use Mojo::File qw(path);
use Mojo::Home;
use Mojolicious::Plugin::AssetPack;
use YAML::PP qw(LoadFile);

sub setup ($server) {
    # setup asset pack, note that the config file is shared with tools/generate-packed-assets
    $server->plugin(AssetPack => LoadFile($server->home->child('assets', 'assetpack.yml')));

    # The feature was added in the 2.14 release, the version check can be removed once openQA depends on a newer version
    $server->asset->store->retries(5) if $Mojolicious::Plugin::AssetPack::VERSION > 2.13;

    # -> read assets/assetpack.def
    local $SIG{CHLD};
    eval { $server->asset->process };
    if (my $assetpack_error = $@) {    # uncoverable statement
        $assetpack_error    # uncoverable statement
          .= 'If you invoked this service for development (from a Git checkout) you probably just need to'
          . ' invoke "make node_modules" before running this service. If you invoked this service via a packaged binary/service'
          . " then there is probably a problem with the packaging.\n"
          if $assetpack_error =~ qr/could not find input asset.*node_modules/i;    # uncoverable statement
        die $assetpack_error;    # uncoverable statement
    }
}

sub _path ($url) { path('assets', ref $url eq 'Mojo::URL' ? $url->path : $url)->realpath->to_rel }

sub list ($server = Mojolicious->new(home => Mojo::Home->new('.'))) {
    setup $server unless $server->can('asset');
    my %asset_urls;
    my $assets_by_checksum = $server->asset->{by_checksum};
    $asset_urls{_path($assets_by_checksum->{$_}->url)} = 1 for keys %$assets_by_checksum;
    my $assets_by_topic = $server->asset->{by_topic};
    for my $topic (keys %$assets_by_topic) {
        $asset_urls{_path($_->url)} = 1 for @{$assets_by_topic->{$topic}};
    }
    say $_ for keys %asset_urls;
}

1;
