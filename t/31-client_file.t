#!/usr/bin/env perl
# Copyright 2018-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Client;
use OpenQA::File;
use Digest::SHA 'sha1_base64';
use Mojo::File qw(path tempfile tempdir);
use OpenQA::Test::TimeLimit '15';

sub file_path { OpenQA::File->new(file => path(@_)) }

subtest 'base' => sub {
    my $file = file_path($FindBin::Bin, "data", "ltp_test_result_format.json");
    ok $file->end;
    $file->read;
    my $content = $file->content();
    $file->encode_content();
    isnt $file->content(), $content or die diag explain $file;
    $file->decode_content();
    is $file->content(), $content, 'decoded content match to original one' or die 'Horrible thing would happen';
};

subtest 'split/join' => sub {
    my $size = file_path($FindBin::Bin, "data", "ltp_test_result_format.json")->size;

    is $size, 6991, 'size matches';

    is OpenQA::File::_chunk_size(20, 10), 2, 'calculated chunk match';
    is OpenQA::File::_chunk_size(21, 10), 3;
    is OpenQA::File::_chunk_size(29, 10), 3;
    is OpenQA::File::_chunk_size(30, 10), 3;
    is OpenQA::File::_chunk_size(31, 10), 4;

    my $pieces = file_path($FindBin::Bin, "data", "ltp_test_result_format.json")->split(2000);

    is $pieces->last->end, $size, 'Last piece end must match with size';

    is $pieces->join(), path($FindBin::Bin, "data", "ltp_test_result_format.json")->slurp, 'Content match'
      or die diag explain $pieces;

    is $pieces->generate_sum(), sha1_base64(path($FindBin::Bin, "data", "ltp_test_result_format.json")->slurp),
      'SHA-1 match'
      or die diag explain $pieces;

    my $t_file = tempfile();
    $pieces->write($t_file);

    is $t_file->slurp, path($FindBin::Bin, "data", "ltp_test_result_format.json")->slurp,
      'Composed content is same as original'
      or die diag explain $pieces;

    my @serialized = $pieces->serialize();
    is scalar @serialized, $pieces->size(), 'Serialized number of files match';
    # Send over the net ..
    my $des_pieces = OpenQA::Files->deserialize(@serialized);    #recompose


    is_deeply $des_pieces, $pieces or die diag explain $des_pieces;

    is $des_pieces->join(), path($FindBin::Bin, "data", "ltp_test_result_format.json")->slurp, 'Content match'
      or die diag explain $des_pieces;

    is $des_pieces->generate_sum(),
      sha1_base64(path($FindBin::Bin, "data", "ltp_test_result_format.json")->slurp), 'SHA-1 match'
      or die diag explain $des_pieces;

    ok $des_pieces->is_sum(sha1_base64(path($FindBin::Bin, "data", "ltp_test_result_format.json")->slurp));
};


subtest 'recompose in-place' => sub {
    my $original = file_path($FindBin::Bin, "data", "ltp_test_result_format.json");

    my $pieces = $original->split(103);

    my $t_dir = tempdir();
    my $copied_file = tempfile();


    # Save pieces to disk
    $_->prepare && Mojo::File->new($t_dir, $_->index)->spurt($_->serialize) for $pieces->each();
    #$pieces->prepare(); it will call prepare for each one

    is $t_dir->list_tree->size, $pieces->last->total;

    # Write piece-by-piece to another file.
    $t_dir->list_tree->shuffle->each(
        sub {
            my $chunk = OpenQA::File->deserialize(path($_)->slurp);
            $chunk->decode_content;
            $chunk->write_content($copied_file);
        });

    my $sha;
    $t_dir->list_tree->shuffle->each(
        sub {
            my $chunk = OpenQA::File->deserialize(path($_)->slurp);
            $chunk->decode_content;
            is $chunk->verify_content($copied_file), 1, 'chunk: ' . $chunk->index . ' verified';
            $sha = $chunk->total_cksum;
        });

    is $sha, OpenQA::File->file_digest($copied_file->to_string), 'SHA-1 Matches';

    is $original->file->slurp, path($copied_file)->slurp, 'Same content';

    $pieces->first->content('42')->write_content($copied_file);    #Let's simulate a writing error
    isnt $sha, sha1_base64(path($copied_file)->slurp), 'SHA-1 Are not matching anymore';
    isnt $original->file->slurp, path($copied_file)->slurp, 'Not same content';

    my $chunk = OpenQA::File->deserialize(path($t_dir->list_tree->first)->slurp);
    ok !$chunk->verify_content($copied_file), 'chunk NOT verified';
};

subtest 'prepare_chunks' => sub {
    my $original = file_path($FindBin::Bin, "data", "ltp_test_result_format.json");

    my $pieces = $original->split(10);

    $pieces->prepare;

    ok $_->cksum, "Checksum present for " . $_->index for $pieces->each;
};

subtest 'verify_chunks' => sub {
    my $original = file_path($FindBin::Bin, "data", "ltp_test_result_format.json");

    my $pieces = $original->split(100000);

    my $t_dir = tempdir();
    my $copied_file = tempfile();

    # Save pieces to disk
    $pieces->spurt($t_dir);

    is $t_dir->list_tree->size, $pieces->last->total;

    OpenQA::Files->write_chunks($t_dir => $copied_file);

    is(OpenQA::Files->verify_chunks($t_dir => $copied_file), undef, 'Verify chunks passes');
    $copied_file->spurt('');

    is(
        OpenQA::Files->verify_chunks($t_dir => $copied_file)->message(),
        'Can\'t verify written data from chunk',
        'Cannot verify chunks passes'
    );
    is $copied_file->slurp, '', 'File is empty now';

    is(OpenQA::Files->write_verify_chunks($t_dir => $copied_file), undef, 'Write and verify passes');

    is $original->file->slurp, path($copied_file)->slurp, 'Same content';

    $pieces->first->content('42')->write_content($copied_file);    #Let's simulate a writing error
    like(
        OpenQA::Files->verify_chunks($t_dir => $copied_file),
        qr/^Can't verify written data from chunk/,
        'Verify chunks fail'
    );
    isnt $original->file->slurp, path($copied_file)->slurp, 'Not same content';
};

sub compare {
    my ($file, $chunk_size) = @_;
    my $original = file_path($FindBin::Bin, "data", $file);
    my $pieces = $original->split($chunk_size);

    is(OpenQA::File::_chunk_size($original->size, $chunk_size), $pieces->size, 'Size and pieces matches!');

    for (my $i = 1; $i <= $pieces->size; $i++) {
        my $piece = $original->get_piece($i => $chunk_size);
        my $from_split = $pieces->get($i - 1);
        is_deeply $piece, $from_split, 'Structs are matching';

        $piece->prepare();
        $from_split->prepare();

        ok $piece->verify_content($original->file->to_string), 'Chunk verified';
        ok $from_split->verify_content($original->file->to_string), 'Chunk verified';

        is_deeply $piece, $from_split, 'Structs are matching after prepare()';
    }
}

subtest 'get_piece' => sub {
    my $file = "ltp_test_result_format.json";
    my $size = file_path($FindBin::Bin, "data", $file)->size;

    compare($file => 1);
    compare($file => 10);
    compare($file => 21);
    compare($file => $size);
};

done_testing();
