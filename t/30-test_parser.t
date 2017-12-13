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
use OpenQA::Parser::LTP;
use Mojo::File qw(path tempdir);
use Data::Dumper;
use Mojo::JSON qw(decode_json encode_json);

subtest 'Result base class object' => sub {
    use OpenQA::Parser::Result;
    my $res = OpenQA::Parser::Result->new();
    $res->{foo} = 2;
    $res->{bar} = 4;
    is_deeply($res->to_hash(), {bar => 4, foo => 2}, 'to_hash maps correctly');
};

sub test_junit_file {
    my $parser = shift;

    is_deeply $parser->tests->first->to_hash,
      {
        'category' => 'tests-systemd',
        'flags'    => {},
        'name'     => '1_running_upstream_tests',
        'script'   => 'unk'
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

    is_deeply $parser->generated_tests_results->last->TO_JSON, $expected_test_result, 'TO_JSON matches';

    my $testdir = tempdir;
    $parser->write_test_result($testdir);
    is $testdir->list_tree->size, 9, '9 test results were written' or diag explain $parser->generated_tests_results;
    $testdir->list_tree->each(
        sub {
            my $res = decode_json $_->slurp;
            is ref $res, "HASH", 'JSON result can be decoded' or diag explain $_->slurp;
            like $_, qr/result-\d_.*\.json/;
            ok exists $res->{result}, 'JSON result can be decoded';
            ok !exists $res->{name},  'JSON result can be decoded';

        });

    $testdir->remove_tree;

    is_deeply $parser->results->last->TO_JSON(), $expected_test_result,
      'Expected test result match - with no include_results'
      or diag explain $parser->results->last->TO_JSON();
    return $expected_test_result;
}

subtest junit_parse => sub {
    my $parser = OpenQA::Parser::JUnit->new;

    my $junit_test_file = path($FindBin::Bin, "data")->child("slenkins_control-junit-results.xml");

    $parser->load($junit_test_file);
    my $expected_test_result = test_junit_file($parser);
    $expected_test_result->{test} = undef;
    is_deeply $parser->results->last->TO_JSON(1), $expected_test_result,
      'Expected test result match - with no include_results - forcing to output the test';
    $expected_test_result->{name} = '9_post-tests_audits';
    delete $expected_test_result->{test};

    is_deeply $parser->results->last->to_hash(), $expected_test_result,
      'Expected test result match - with no include_results - forcing to output the test';
    delete $expected_test_result->{name};

    $parser = OpenQA::Parser::JUnit->new;

    $parser->include_results(1);
    $parser->load($junit_test_file);

    is $parser->results->size, 9,
      'Generated 9 openQA tests results';    # 9 testsuites with all cumulative results for openQA


    is_deeply $parser->results->last->TO_JSON(0), $expected_test_result, 'Test is hidden';

    $expected_test_result->{test} = {
        'category' => 'tests-systemd',
        'flags'    => {},
        'name'     => '9_post-tests_audits',
        'script'   => 'unk'
    };

    is_deeply $parser->results->last->TO_JSON(1), $expected_test_result, 'Test is showed';
};

sub test_ltp_file {
    my $p = shift;
    is $p->results->size, 6, 'Expected 6 results';
    my $i = 2;
    $p->results->each(
        sub {
            is $_->status, 'pass', 'Tests passed';
            ok !!$_->environment, 'Environment is present';
            ok !!$_->test,        'Test information is present';
            is $_->environment->gcc, 'gcc (SUSE Linux) 7.2.1 20170927 [gcc-7-branch revision 253227]',
              'Environment information matches';
            is $_->test->result, 'TPASS', 'subtest result is TPASS';
            is $_->test_fqn, "LTP:cpuhotplug:cpuhotplug0$i", "test_fqn matches and are different";
            $i++;
        });
    is $p->results->get(0)->environment->gcc, 'gcc (SUSE Linux) 7.2.1 20170927 [gcc-7-branch revision 253227]',
      'Environment information matches';
}

sub test_ltp_file_v2 {
    my $p = shift;
    is $p->results->size, 4, 'Expected 4 results';
    is $p->extra->first->gcc, 'gcc (SUSE Linux) 7.2.1 20171020 [gcc-7-branch revision 253932]';
    my $i = 2;
    $p->results->each(
        sub {
            is $_->status, 'pass', 'Tests passed';
            ok !!$_->environment, 'Environment is present';
            ok !!$_->test,        'Test information is present';
            is $_->environment->gcc, undef;
            is $_->test->result, 'PASS', 'subtest result is PASS';
            like $_->test_fqn, qr/LTP:/, "test_fqn is there";
            $i++;
        });
}

subtest ltp_parse => sub {

    my $parser = OpenQA::Parser::LTP->new;

    my $ltp_test_result_file = path($FindBin::Bin, "data")->child("ltp_test_result_format.json");

    $parser->load($ltp_test_result_file);

    test_ltp_file($parser);


    my $parser_format_v2 = OpenQA::Parser::LTP->new;

    $ltp_test_result_file = path($FindBin::Bin, "data")->child("new_ltp_result_array.json");

    $parser_format_v2->load($ltp_test_result_file);

    test_ltp_file_v2($parser_format_v2);
};

subtest 'serialize/deserialize LTP' => sub {
    my $parser = OpenQA::Parser::LTP->new;

    my $ltp_test_result_file = path($FindBin::Bin, "data")->child("ltp_test_result_format.json");

    $parser->load($ltp_test_result_file);
    my $obj_content  = $parser->serialize();
    my $deserialized = OpenQA::Parser::LTP->new->deserialize($obj_content);
    ok "$deserialized" ne "$parser", "Different objects";
    test_ltp_file($parser);
    test_ltp_file($deserialized);
};

subtest 'serialize/deserialize LTP v2' => sub {
    my $parser = OpenQA::Parser::LTP->new;

    my $ltp_test_result_file = path($FindBin::Bin, "data")->child("new_ltp_result_array.json");

    $parser->load($ltp_test_result_file);
    my $obj_content  = $parser->serialize();
    my $deserialized = OpenQA::Parser::LTP->new->deserialize($obj_content);
    ok "$deserialized" ne "$parser", "Different objects";
    test_ltp_file_v2($parser);
    test_ltp_file_v2($deserialized);
};


subtest 'serialize/deserialize Junit' => sub {
    my $parser = OpenQA::Parser::JUnit->new;

    my $junit_test_file = path($FindBin::Bin, "data")->child("slenkins_control-junit-results.xml");

    $parser->load($junit_test_file);
    my $obj_content  = $parser->serialize();
    my $deserialized = OpenQA::Parser::JUnit->new()->deserialize($obj_content);
    ok "$deserialized" ne "$parser", "Different objects";
    diag("Not-Serializied test");
    test_junit_file($parser);
    diag("Serializied test");
    test_junit_file($deserialized);
};

done_testing;

1;
