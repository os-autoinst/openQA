package OpenQA::WebAPI::AssetPipe;
use Mojo::Base "Mojolicious::Plugin::AssetPack::Pipe";
use Mojolicious::Plugin::AssetPack::Util qw(diag DEBUG);

# rewrite links to chosen images - actually something that the
# Fetch pipe should do itself (https://github.com/jhthorsen/mojolicious-plugin-assetpack/issues/94)
sub process {
    my ($self, $assets) = @_;

    # Normally a Mojolicious::Plugin::AssetPack::Store object
    my $store = $self->assetpack->store;
    my $route = $self->assetpack->route;

    # Loop over Mojolicious::Plugin::AssetPack::Asset objects
    $assets->each(
        sub {
            my ($asset, $index) = @_;

            # Skip every file that is not css
            return if $asset->format ne "css";

            return if $asset->url !~ /\/chosen.css/;

            # Change $attr if this pipe will modify $asset attributes
            my $attr    = $asset->TO_JSON;
            my $content = $asset->content;

            print $content;

            # Private name to load/save meta data under
            $attr->{key} = "openqapipe3";

            # Return asset if already processed
            my $file = $store->load($attr);
            if ($file) {
                return $asset->content($file);
            }

            # Process asset content
            my $cssurl = $asset->url;
            $cssurl =~ s,chosen.css,chosen-sprite.png,;

            my $sprite = $store->asset($cssurl);
            my $path   = $route->render($sprite->TO_JSON);

            $content =~ s!\Qurl('chosen-sprite.png')\E!url($path)!g;
            $asset->content($content);
        });
}

1;
