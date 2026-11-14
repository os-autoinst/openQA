# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;
use Mojo::Base -base, -signatures;

use FindBin;
use lib "$FindBin::Bin/../lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '15';
use Test::Warnings ':report_warnings';

use Mojo::File qw(path);

my $root = path($FindBin::Bin, '..');
my $fa_css = join '', map {
    my $file = $root->child(qw(node_modules @fortawesome fontawesome-free css), "$_.css");
    -e $file ? $file->slurp : '';
} qw(fontawesome solid regular brands);

sub families_in ($css) {
    my %families;
    for my $family ($css =~ /font-family:\s*"([^"]+)"/g) { $families{$family} = 1 }
    return %families;
}

sub classes_in ($css) {
    my %classes;
    for my $class ($css =~ /\.(fa-[a-z0-9-]+)\b/g) { $classes{$class} = 1 }
    return %classes;
}

sub files_under ($dir, @exts) {
    my @files;
    my @queue = ($dir);
    while (my $current = shift @queue) {
        for my $entry (@{path($current)->list}) {
            if (-d $entry) { push @queue, $entry->to_string; next }
            my $name = $entry->to_string;
            next if @exts && !grep { $name =~ /\.\Q$_\E$/ } @exts;
            push @files, $name;
        }
    }
    return @files;
}

sub style_files ($root) {
    my @files = files_under($root->child('assets/stylesheets')->to_string, 'scss', 'css');
    my @sorted = sort @files;
    return @sorted;
}

sub source_files ($root, @dirs) {
    my @files = map { files_under($_) } map { $root->child($_)->to_string } @dirs;
    my @sorted = sort @files;
    return @sorted;
}

subtest 'installed Font Awesome package provides the families the web UI refers to' => sub {
    my %families = families_in($fa_css);
    my ($indirect) = $fa_css =~ /--fa-style-family-classic:\s*var\((--fa[a-z0-9-]*)\)/;
    ok $indirect, 'the style family alias the web UI uses is defined via a package custom property';
    my (undef, $family) = $fa_css =~ /\Q$indirect\E\s*:\s*(["'])([^"']+)\1/;
    ok $family && $families{$family}, 'the alias resolves to a family the package provides'
      or diag "alias chain: $indirect -> $family, families: ", join ', ', keys %families;    # uncoverable statement

    my @unknown;
    for my $file (style_files($root)) {
        my $sheet = path($file)->slurp;
        for my $declaration ($sheet =~ /font-family:\s*([^;]+)/g) {
            for my $quoted ($declaration =~ /(['"])Font Awesome[^'"]*\1/g) {
                my $family = $quoted =~ s/^['"]|['"]$//r;    # uncoverable statement
                push @unknown, "$file refers to $family" unless $families{$family};    # uncoverable statement
            }
        }
    }
    is @unknown, 0, 'no Font Awesome family name is hard-coded to a version the package does not provide'
      or diag join "\n", @unknown;

    my %fa_vars_used;
    for my $file (style_files($root)) {
        my $sheet = path($file)->slurp;
        while ($sheet =~ /var\((--fa[a-z0-9-]*)\)/g) { $fa_vars_used{$1} = 1 }
    }
    my %fa_defined;
    while ($fa_css =~ /(--fa[a-z0-9-]*)\s*:/g) { $fa_defined{$1} = 1 }
    my @undefined = grep { !$fa_defined{$_} } sort keys %fa_vars_used;
    is @undefined, 0, 'the web UI resolves Font Awesome properties via custom properties defined by the package'
      or diag join ', ', @undefined;    # uncoverable statement
};

subtest 'web UI relies on the helper the Bootstrap package provides' => sub {
    ok -e $root->child(qw(node_modules bootstrap scss helpers _visually-hidden.scss)),
      'Bootstrap provides the .visually-hidden helper the web UI uses';
};

subtest 'every icon class used by the web UI is known to Font Awesome' => sub {
    my %known = classes_in($fa_css);
    ok keys %known, 'icon classes defined by the installed Font Awesome package';

    my @unknown;
    for my $file ((source_files($root, 'templates', 'assets/javascripts'), style_files($root))) {
        my $source = path($file)->slurp;
        for my $class ($source =~ /(?<!-)\b(fa-[a-z0-9-]+)\b/g) {
            next if $known{$class};
            push @unknown, "$file uses $class which is not defined by Font Awesome";    # uncoverable statement
        }
    }
    is @unknown, 0, 'every icon class used by the web UI is defined by Font Awesome'
      or diag join "\n", @unknown;
};

done_testing();
