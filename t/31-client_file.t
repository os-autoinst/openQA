#!/usr/bin/env perl -w
# Copyright (C) 2018 SUSE LLC
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License along
# with this program; if not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use FindBin;
use lib ("$FindBin::Bin/lib", "../lib", "lib");
use Test::More;
use OpenQA::Client;
use OpenQA::File 'path';
use Digest::SHA 'sha1_base64';
use Mojo::File qw(tempfile tempdir);

subtest 'split/join' => sub {

    is path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->size, 6991, 'size matches';

    is OpenQA::File::_chunk_size(20, 10), 2, 'calculated chunk match';
    is OpenQA::File::_chunk_size(21, 10), 3;
    is OpenQA::File::_chunk_size(29, 10), 3;
    is OpenQA::File::_chunk_size(30, 10), 3;
    is OpenQA::File::_chunk_size(31, 10), 4;

    my $pieces = path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->split(2000);

    is $pieces->join(), path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->slurp, 'Content match'
      or die diag explain $pieces;

    is $pieces->generate_sum(), sha1_base64(path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->slurp),
      'SHA-1 match'
      or die diag explain $pieces;

    my $t_file = tempfile();
    $pieces->write($t_file);

    is $t_file->slurp, path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->slurp,
      'Composed content is same as original'
      or die diag explain $pieces;

    my @serialized = $pieces->serialize();
    is scalar @serialized, $pieces->size(), 'Serialized number of files match';
    # Send over the net ..
    my $des_pieces = OpenQA::Files->deserialize(@serialized);    #recompose


    is_deeply $des_pieces, $pieces or die diag explain $des_pieces;

    is $des_pieces->join(), path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->slurp, 'Content match'
      or die diag explain $des_pieces;

    is $des_pieces->generate_sum(),
      sha1_base64(path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->slurp), 'SHA-1 match'
      or die diag explain $des_pieces;

    ok $des_pieces->is_sum(sha1_base64(path($FindBin::Bin, "data")->child("ltp_test_result_format.json")->slurp));
};


subtest 'recompose in-place' => sub {
    my $original = path($FindBin::Bin, "data")->child("ltp_test_result_format.json");

    my $pieces = $original->split(203);

    my $t_dir       = tempdir();
    my $copied_file = tempfile();

    # Save pieces to disk
    Mojo::File->new($t_dir, $_->index)->spurt($_->serialize) for $pieces->each();

    is $t_dir->list_tree->size, $pieces->last->total;

    # Write piece-by-piece to another file.
    $t_dir->list_tree->shuffle->each(
        sub {
            my $chunk = OpenQA::File->deserialize(Mojo::File->new($_)->slurp);
            $chunk->write_content($copied_file);
        });

    my $sha;
    $t_dir->list_tree->shuffle->each(
        sub {
            my $chunk = OpenQA::File->deserialize(Mojo::File->new($_)->slurp);
            ok $chunk->verify_content($copied_file), 'chunk: ' . $chunk->index . ' verified';
            $sha = $chunk->total_cksum;
        });

    is $sha, sha1_base64(Mojo::File->new($copied_file)->slurp), 'SHA-1 Matches';

    is $original->slurp, Mojo::File->new($copied_file)->slurp, 'Same content';

    $pieces->first->content('42')->write_content($copied_file);    #Let's simulate a writing error
    isnt $sha, sha1_base64(Mojo::File->new($copied_file)->slurp), 'SHA-1 Are not matching anymore';
    isnt $original->slurp, Mojo::File->new($copied_file)->slurp, 'Not same content';

    my $chunk = OpenQA::File->deserialize(Mojo::File->new($t_dir->list_tree->first)->slurp);
    ok !$chunk->verify_content($copied_file), 'chunk NOT verified';
};

subtest 'verify_chunks' => sub {
    my $original = path($FindBin::Bin, "data")->child("ltp_test_result_format.json");

    my $pieces = $original->split(10);

    my $t_dir       = tempdir();
    my $copied_file = tempfile();

    # Save pieces to disk
    $pieces->spurt($t_dir);

    is $t_dir->list_tree->size, $pieces->last->total;

    OpenQA::Files->write_chunks($t_dir => $copied_file);

    ok(OpenQA::Files->verify_chunks($t_dir => $copied_file), 'Verify chunks passes');
    $copied_file->spurt('');

    ok(!OpenQA::Files->verify_chunks($t_dir => $copied_file), 'Cannot verify chunks passes');
    is $copied_file->slurp, '', 'File is empty now';
    ok(OpenQA::Files->write_verify_chunks($t_dir => $copied_file), 'Write and verify passes');
    is $original->slurp, Mojo::File->new($copied_file)->slurp, 'Same content';

    $pieces->first->content('42')->write_content($copied_file);    #Let's simulate a writing error
    ok(!OpenQA::Files->verify_chunks($t_dir => $copied_file), 'Verify chunks fail');
    isnt $original->slurp, Mojo::File->new($copied_file)->slurp, 'Not same content';
};

done_testing();
1;
