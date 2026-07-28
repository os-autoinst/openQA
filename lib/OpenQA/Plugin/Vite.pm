# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Plugin::Vite;
use Mojo::Base 'Mojolicious::Plugin', -signatures;
use Mojo::File qw(path);
use JSON::PP qw(decode_json);

sub register ($self, $app, $conf = {}) {
    my $dist_path = $app->home->child('public', 'dist');
    # Robustness: If app->home is set to something else (e.g. t/data), look in current dir
    unless (-d $dist_path) {
        my $root_dist = path('public', 'dist');
        if (-d $root_dist) {
            $dist_path = $root_dist->realpath;
            push @{$app->static->paths}, $root_dist->dirname->realpath->to_string;
        }
    }

    my $manifest_file = $dist_path->child('.vite', 'manifest.json');
    my $manifest;

    # Helper to get the correct asset URL
    $app->helper(
        vite => sub ($c, $name) {
            # In development mode, proxy to the Vite dev server
            if ($app->mode eq 'development' && !$ENV{OPENQA_VITE_PRODUCTION}) {
                # Add test suffix if needed
                my $test_name = $name;
                if ($app->mode eq 'test' || ($c->stash('mode') // '') eq 'test') {
                    $test_name =~ s/\.(js|css)$/.test.$1/;
                }
                # Vite dev server serves from / (root) which we've set to 'assets/'
                # But we need to point to our entry points
                if ($test_name =~ /\.js$/) {
                    return $c->url_for("/entry/$test_name");
                }
                elsif ($test_name =~ /\.css$/) {
                    my $scss_name = $test_name;
                    $scss_name =~ s/\.css$/.scss/;
                    return $c->url_for("/entry/$scss_name");
                }
                else {
                    return $c->url_for("/images/$name");
                }
            }

            # In production, use the manifest
            unless ($manifest) {
                if (-e $manifest_file) {
                    $manifest = decode_json($manifest_file->slurp);
                }
                else {
                    $app->log->warn("Vite manifest not found at $manifest_file. Did you run 'npm run build'?");
                    $manifest = {};
                }
            }

            my $test_name = $name;
            if ($app->mode eq 'test' || $c->stash('mode') eq 'test') {
                $test_name =~ s/\.(js|css)$/.test.$1/;
            }

            # Try to find the entry in the manifest
            my $entry;
            for my $candidate ($test_name, $name) {
                # 1. Exact match
                $entry = $manifest->{$candidate};
                last if $entry;

                # 2. Try with prefixes
                my $entry_path = $candidate;
                if ($entry_path =~ /\.css$/) {
                    $entry_path =~ s/\.css$/.scss/;
                    $entry = $manifest->{"entry/$entry_path"} || $manifest->{"stylesheets/$entry_path"};
                }
                elsif ($entry_path =~ /\.js$/) {
                    $entry = $manifest->{"entry/$entry_path"} || $manifest->{"javascripts/$entry_path"};
                }
                elsif ($entry_path =~ /\.(png|svg|jpg|jpeg|gif|ico)$/) {
                    $entry = $manifest->{"images/$entry_path"};
                }
                last if $entry;

                # 3. Try searching by 'name' field in manifest
                foreach my $key (keys %$manifest) {
                    if (($manifest->{$key}->{name} // '') eq $candidate) {
                        $entry = $manifest->{$key};
                        last;
                    }
                }
                last if $entry;
            }

            if ($entry) {
                return $c->url_for('/dist/' . $entry->{file});
            }

            # Fallback to public/
            return $c->url_for('/' . $name);
        });

    # Override the 'asset' helper for backward compatibility
    $app->helper(
        asset => sub ($c, $name) {
            my $url = $c->vite($name);
            if ($name =~ /\.js$/) {
                return $c->javascript($url, type => 'module');
            }
            elsif ($name =~ /\.css$/) {
                return $c->stylesheet($url);
            }
            else {
                return $url;
            }
        });
}

1;
