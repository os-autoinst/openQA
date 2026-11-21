# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Test::Screenshot;
use Mojo::Base -strict, -signatures;

use Compress::Zlib qw(uncompress);
use Exporter 'import';

our @EXPORT_OK = qw(load_png compare_png);

# minimal decoder for the 8-bit PNGs Chrome writes; PerlMagick is not available in CI
sub load_png ($bytes) {
    die 'not a PNG' if "\x89PNG\r\n\x1a\n" ne substr $bytes, 0, 8;    # uncoverable statement
    my ($width, $height, $depth, $color, $interlace, $idat, $offset) = (0, 0, 0, 0, 0, '', 8);
    while ($offset < length $bytes) {
        die 'truncated PNG chunk' if $offset + 8 > length $bytes;    # uncoverable statement
        my $length = unpack 'N', substr $bytes, $offset, 4;
        my $type = substr $bytes, $offset + 4, 4;
        my $data = substr $bytes, $offset + 8, $length;
        if ($type eq 'IHDR') {
            ($width, $height, $depth, $color, undef, undef, undef, $interlace) = unpack 'N2C5', $data;
        }
        elsif ($type eq 'IDAT') { $idat .= $data }
        elsif ($type eq 'IEND') { last }
        $offset += $length + 12;
    }
    die 'interlaced PNG not supported' if $interlace;    # uncoverable statement
    die 'only 8-bit PNG supported' if $depth != 8;    # uncoverable statement
    my $channels = $color == 6 ? 4 : $color == 2 ? 3 : $color == 0 ? 1 : die "color type $color not supported";
    my $stride = $width * $channels;
    my $raw = uncompress $idat // die 'cannot decompress PNG data';
    my $pos = 0;
    my @pixels;
    my @previous = (0) x $stride;
    for my $row (0 .. $height - 1) {
        my $filter = ord substr $raw, $pos, 1;
        $pos += 1;
        die "filter $filter not supported" if $filter > 4;    # uncoverable statement
        my @line = map { ord } split //, substr $raw, $pos, $stride;
        $pos += $stride;
        for my $i (0 .. $stride - 1) {
            my $left = $i >= $channels ? $line[$i - $channels] : 0;
            my $up = $previous[$i];
            my $upper_left = $i >= $channels ? $previous[$i - $channels] : 0;
            if ($filter == 1) { $line[$i] = ($line[$i] + $up) % 256 }
            elsif ($filter == 2) { $line[$i] = ($line[$i] + $left) % 256 }
            elsif ($filter == 3) { $line[$i] = ($line[$i] + int(($left + $up) / 2)) % 256 }
            elsif ($filter == 4) { $line[$i] = ($line[$i] + paeth($left, $up, $upper_left)) % 256 }
        }
        @previous = @line;
        push @pixels, [@line];
    }
    return {width => $width, height => $height, channels => $channels, pixels => \@pixels};
}

sub paeth ($x, $y, $z) {
    my $p = $x + $y - $z;
    my $pa = abs $p - $x;
    my $pb = abs $p - $y;
    my $pc = abs $p - $z;
    return $pa <= $pb && $pa <= $pc ? $x : $pb <= $pc ? $y : $z;
}

# percentage of pixels with any channel differing by more than $tolerance
sub compare_png ($one, $other, $tolerance = 24) {
    return 100
      if $one->{width} != $other->{width}
      || $one->{height} != $other->{height}
      || $one->{channels} != $other->{channels};
    my $differing = 0;
    for my $row (0 .. $one->{height} - 1) {
        my $current = $one->{pixels}[$row];
        my $reference = $other->{pixels}[$row];
        my $pixel_differs = 0;
        for my $i (0 .. $one->{width} * $one->{channels} - 1) {
            $pixel_differs = 1 if abs($current->[$i] - $reference->[$i]) > $tolerance;
        }
        $differing++ if $pixel_differs;
    }
    return $differing / ($one->{width} * $one->{height}) * 100;
}

1;
