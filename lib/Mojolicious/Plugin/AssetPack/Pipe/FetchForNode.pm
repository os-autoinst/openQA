# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

# NOTE: This file is based on Mojolicious::Plugin::AssetPack::Pipe::Fetch but
# was changed to handle local relative paths within the node_modules directory
# instead of remote sources.

package Mojolicious::Plugin::AssetPack::Pipe::FetchForNode;
use Mojo::Base 'Mojolicious::Plugin::AssetPack::Pipe', -signatures;
use Mojo::URL;

my %FORMATS = (
    css => {
        re => qr{url\((['"]{0,1})(.*?)\1\)},
        pos => sub ($start, $url, $quotes) {
            my $len = length $url;
            return $start - length($quotes) - $len - 1, $len;
        },
    },
);

sub _handle_related ($self, $visited, $url) {
    my $related = $visited->{$url};
    return $related if $related;
    $related = $self->assetpack->store->asset($url) or die "AssetPack was unable to locate related asset '$url'";
    $self->assetpack->process($related->name, $related);

    my $path = $self->assetpack->route->render($related->TO_JSON);
    # turn path from e.g. '../../..//asset/7f7208e7b2/forkawesome-webfont.woff2'
    # to '../../asset/7f7208e7b2/forkawesome-webfont.woff2'
    $path =~ s!^/!!;

    my $up = join '', map { '../' } $path =~ m!\/!g;
    return $visited->{$url} = "$up$path";
}

sub process ($self, $assets) {
    my %visited;
    $assets->each(
        sub ($asset, $index) {
            my $base = Mojo::URL->new($asset->url);
            return undef unless $base =~ /\.\.\/node_modules/;
            return undef unless my $format = $FORMATS{$asset->format};

            my $content = $asset->content;
            my $re = $format->{re};
            while ($content =~ /$re/g) {
                my ($quotes, $matched_url) = ($1, $2);
                next if $matched_url =~ /^(?:\#|data:)/;    # skip e.g. "data:image/svg+xml..." and "#foo"

                my $url = Mojo::URL->new($matched_url)->base($base)->to_abs->fragment(undef)->query(undef);
                my $related = $self->_handle_related(\%visited, $url);
                my ($start, $len) = $format->{pos}->(pos($content), $matched_url, $quotes);
                substr $content, $start, $len, Mojo::URL->new($related)->query(Mojo::Parameters->new);
                pos($content) = $start + $len;
            }
            $asset->content($content);
        });
}

1;
