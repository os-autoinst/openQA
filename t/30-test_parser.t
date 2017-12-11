#!/usr/bin/env perl -w
# Copyright (C) 2017 SUSE LLC
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
use OpenQA;
use Test::Output 'combined_like';
use OpenQA::Parser;
use OpenQA::Parser::JUnit;
use Mojo::File qw(path tempdir);
use Data::Dumper;
use Mojo::JSON qw(decode_json encode_json);

subtest parse => sub {
    my $parser = OpenQA::Parser::JUnit->new;

    my $junit_test_file = path($FindBin::Bin, "data")->child("slenkins_control-junit-results.xml");

    $parser->load($junit_test_file);

    is_deeply $parser->tests->first->to_hash,
      {
        'category' => 'tests-systemd',
        'flags'    => {},
        'name'     => '1_running_upstream_tests',
        'script'   => undef
      };

    is $parser->tests->search("name", qr/1_running_upstream_tests/)->first()->name, '1_running_upstream_tests';
    is $parser->tests->search("name", qr/1_running_upstream_tests/)->size, 1;

    is $parser->tests->size, 9,
      'Generated 9 openQA tests results';    # 9 testsuites with all cumulative results for openQA
    is $parser->generated_tests_results->size, 9, 'Object contains 9 testsuites';

    is $parser->results->search_in_details("text", qr/tests-systemd/)->size, 166,
      'Overall 9 testsuites, 166 tests are for systemd';
    is $parser->generated_tests_output->size, 166, "Outputs of systemd tests details matches";

    my $resultsdir = tempdir;
    $parser->write_output($resultsdir);
    is $resultsdir->list_tree->size, 166, '166 test outputs were written';
    $resultsdir->list_tree->each(
        sub {
            ok $_->slurp =~ /# system-out:|# running upstream test/, 'Output result was written correctly';
        });

    my $testdir = tempdir;
    $parser->write_test_result($testdir);
    is $testdir->list_tree->size, 9, '9 test outputs were written';
    $testdir->list_tree->each(
        sub {
            my $res = decode_json $_->slurp;
            ok exists $res->{result}, 'JSON result can be decoded';
        });

    $testdir->remove_tree;

    my $expected_test_result = {
        dents   => 0,
        details => [
            {
                result => 'ok',
                text   => 'tests-systemd-9_post-tests_audits-1.txt',
                title  => 'audit with systemd-analyze blame'
            },
            {
                result => 'ok',
                text   => 'tests-systemd-9_post-tests_audits-2.txt',
                title  => 'audit with systemd-analyze critical-chain'
            },
            {
                result => 'ok',
                text   => 'tests-systemd-9_post-tests_audits-3.txt',
                title  => 'audit with systemd-cgls'
            }
        ],
        result => 'ok'
    };
    is_deeply $parser->results->last->to_hash(), $expected_test_result,
      'Expected test result match - with no include_results';

    $expected_test_result->{test} = undef;
    is_deeply $parser->results->last->to_hash(1), $expected_test_result,
      'Expected test result match - with no include_results - forcing to output the test';
    delete $expected_test_result->{test};

    $parser = OpenQA::Parser::JUnit->new;

    $parser->include_results(1);
    $parser->load($junit_test_file);


    is $parser->results->size, 9,
      'Generated 9 openQA tests results';    # 9 testsuites with all cumulative results for openQA


    is_deeply $parser->results->last->to_hash(0), $expected_test_result, 'Test is hidden';

    $expected_test_result->{test} = {
        'category' => 'tests-systemd',
        'flags'    => {},
        'name'     => '9_post-tests_audits',
        'script'   => undef
    };

    is_deeply $parser->results->last->to_hash(1), $expected_test_result, 'Test is showed';
};


done_testing;

1;
