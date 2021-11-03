#!/usr/bin/env perl
# Copyright 2017-2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Test::Most;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";
use OpenQA::Test::TimeLimit '10';
use OpenQA;
use Test::Output 'combined_like';
use OpenQA::Parser qw(parser p);
use OpenQA::Parser::Format::JUnit;
use OpenQA::Parser::Format::LTP;
use OpenQA::Parser::Format::XUnit;
use OpenQA::Parser::Format::TAP;
use OpenQA::Parser::Format::IPA;
use Mojo::File qw(path tempdir);
use Mojo::JSON qw(decode_json encode_json);

subtest 'Result base class object' => sub {
    use OpenQA::Parser::Result;
    my $res = OpenQA::Parser::Result->new();
    $res->{foo} = 2;
    $res->{bar} = 4;
    is_deeply($res->to_hash(), {bar => 4, foo => 2}, 'to_hash maps correctly') or die diag explain $res;

    my $j = $res->to_json;
    my $res2 = OpenQA::Parser::Result->new()->from_json($j);
    is_deeply($res2->to_hash(), {bar => 4, foo => 2}, 'to_hash maps correctly') or die diag explain $res2;
};

subtest 'Results base class object' => sub {
    use OpenQA::Parser::Results;
    my $res = OpenQA::Parser::Results->new();

    $res->add({foo => 'bar'});

    my $json_encode = $res->to_json;

    my $deserialized = OpenQA::Parser::Results->from_json($json_encode);
    is $deserialized->first->{foo}, 'bar' or diag explain $deserialized;

    $res = OpenQA::Parser::Results->new();

    $res->add({bar => 'baz'});

    my $serialized = $res->serialize;

    $deserialized = OpenQA::Parser::Results->new->deserialize($serialized);
    is $deserialized->first->{bar}, 'baz' or diag explain $deserialized;
};

{
    package Dummy;    # uncoverable statement
    sub new {
        my $class = shift;
        my $self = {};
        bless $self, $class;
        $self->{test} = 1;
        return $self;
    }
}

{
    package Dummy2;    # uncoverable statement count:2

    sub new {
        my $class = shift;
        my $self = [];
        bless $self, $class;
        @{$self} = qw(1 2 3);
        return $self;
    }
}

{
    package Dummy2to;    # uncoverable statement count:2
    sub new {
        my $class = shift;
        my $self = [];
        bless $self, $class;
        @{$self} = qw(a b c);
        return $self;
    }
    sub to_array { [@{shift()}] }
}

{
    package Dummy3to;    # uncoverable statement count:2
    sub new {
        my $class = shift;
        my $self = {};
        bless $self, $class;
        $self->{foobar} = 'barbaz';
        return $self;
    }
    sub to_hash { return {%{shift()}} }
}

{
    package Dummy3;    # uncoverable statement count:2
    use Symbol;

    sub new {
        my $class = shift;
        my $self = gensym;
        bless $self, $class;
        return $self;
    }
}

{
    package NestedResults;    # uncoverable statement count:2
    use Mojo::Base 'OpenQA::Parser::Results';
}

{
    package NestedResult;
    use Mojo::Base 'OpenQA::Parser::Result';

    # uncoverable statement count:2
    has result1 => sub { NestedResult->new() };
    # uncoverable statement count:2
    has result2 => sub { NestedResult->new() };
    has 'val';
}

subtest 'Parser base class object' => sub {
    my $res = parser('Base');
    ok $res->parse eq "$res";
    $res->include_content(1);
    $res->{content} = 42;
    $res->_add_test({name => 'foo'});
    is $res->content, 42;
    is $res->include_content, 1;
    is $res->generated_tests->first->name, 'foo';
    $res->reset();
    is $res->include_content, undef or diag explain $res;
    is $res->content, undef or diag explain $res;
    is $res->generated_tests->size, 0, '0 tests';

    my $meant_to_fail = OpenQA::Parser->new;
    eval { $meant_to_fail->parse() };
    ok $@;
    like $@, qr/parse\(\) not implemented by base class/, 'Base class does not parse data';

    eval { $meant_to_fail->load() };
    ok $@;
    like $@, qr/You need to specify a file/, 'load croaks if no file is specified';

    eval { $meant_to_fail->load('thiswontexist') };
    ok $@;
    like $@, qr/Can't open file \"thiswontexist\"/, 'load confesses if file is invalid';

    use Mojo::File 'tempfile';
    my $tmp = tempfile;
    eval { $meant_to_fail->load($tmp) };
    ok $@;
    like $@, qr/Failed reading file $tmp/, 'load confesses if file is invalid';

    my $good_parser = parser('Base');

    eval { $good_parser->write_output() };
    ok $@;
    like $@, qr/You need to specify a directory/, 'write_output needs a directory as argument';

    eval { $good_parser->write_test_result() };
    ok $@;
    like $@, qr/You need to specify a directory/, 'write_test_result needs a directory as argument';

    $good_parser->results->add({foo => 1});
    is $good_parser->results->size, 1;
    is_deeply $good_parser->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::DATA_FIELD()}, {foo => 1};

    $good_parser->results->remove(0);
    is $good_parser->results->size, 0;

    $good_parser->results->add(Dummy->new);

    combined_like { $good_parser->_build_tree }
    qr/Serialization is officially supported only if object can be hashified with \-\>to_hash\(\)/,
      'serialization support warns';

    $good_parser->results->remove(0);

    $good_parser->results->add(Dummy2->new);
    combined_like { $good_parser->_build_tree }
    qr/Serialization is officially supported only if object can be turned into an array with \-\>to_array\(\)/,
      'serialization support warns';

    combined_like {
        is_deeply $good_parser->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::DATA_FIELD()},
          [qw(1 2 3)];
    }
    qr/Serialization is officially supported only if object can be turned into an array with \-\>to_array\(\)/,
      'serialization support warns';

    $good_parser->results->add({test => 'bar'});

    $good_parser->results->add(Dummy3->new);
    combined_like { $good_parser->_build_tree } qr/Data type with format not supported for serialization/,
      'serialization support warns';
    $good_parser->results->remove(2);

    is $good_parser->results->size, 2, '2 results';
    combined_like {
        is_deeply $good_parser->_build_tree->{generated_tests_results}->[1]->{OpenQA::Parser::DATA_FIELD()},
          {test => 'bar'}
    }
    qr/Serialization is officially supported only if object can be turned into an array with \-\>to_array\(\)/,
      'serialization support warns';

    my $copy;
    combined_like { $copy = parser("Base")->_load_tree($good_parser->_build_tree) }
    qr/Serialization is officially supported only if object can be turned into an array with \-\>to_array\(\)/,
      'serialization support warns';
    combined_like {
        is_deeply $copy->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::DATA_FIELD()}, [qw(1 2 3)]
          or diag explain $copy->_build_tree->{generated_tests_results}
    }
    qr/Serialization is officially supported only if object can be turned into an array with \-\>to_array\(\)/,
      'serialization support warns';
    combined_like {
        is_deeply $copy->_build_tree->{generated_tests_results}->[1]->{OpenQA::Parser::DATA_FIELD()}, {test => 'bar'}
          or die diag explain $good_parser->_build_tree
    }
    qr/Serialization is officially supported only if object can be turned into an array with \-\>to_array\(\)/,
      'serialization support warns';

    $good_parser->results->remove(1);
    $good_parser->results->remove(0);

    is $good_parser->results->size, 0;

    $good_parser->results->add(Dummy2to->new);

    is_deeply $good_parser->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::DATA_FIELD()}, [qw(a b c)]
      or diag explain $good_parser->_build_tree->{generated_tests_results};

    $copy = parser("Base")->_load_tree($good_parser->_build_tree);
    is_deeply $copy->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::DATA_FIELD()}, [qw(a b c)]
      or diag explain $copy->_build_tree->{generated_tests_results};


    my $alt_parser = parser("Base");

    $alt_parser->results->add(Dummy3to->new);

    is $alt_parser->results->first->{foobar}, 'barbaz', 'Result is there';

    $copy = parser("Base")->_load_tree($alt_parser->_build_tree);

    is $copy->results->first->{foobar}, 'barbaz', 'Result is there';
};

subtest 'Nested results' => sub {

    my $deep_p = parser('Base');

    my $r = NestedResult->new(
        result1 => NestedResult->new(val => 'result_1_result_1'),
        result2 => NestedResult->new(val => 'result_1_result_2'));

    is_deeply(NestedResult->deserialize($r->serialize()), $r);

    is_deeply $r->gen_tree_el,
      {
        '__data__' => {
            'result1' => {
                '__data__' => {
                    'val' => 'result_1_result_1'
                },
                '__type__' => 'NestedResult'
            },
            'result2' => {
                '__data__' => {
                    'val' => 'result_1_result_2'
                },
                '__type__' => 'NestedResult'
            }
        },
        '__type__' => 'NestedResult'
      },
      'gen_tree_el is working correctly'
      or die diag explain $r->gen_tree_el;

    $deep_p->results->add(
        NestedResult->new(
            result1 => NestedResult->new(
                result1 => NestedResult->new(val => 'result_1_result_1'),
                result2 => NestedResult->new(val => 'result_1_result_2')
            ),
            result2 => NestedResult->new(
                result1 => NestedResult->new(val => 'result_2_result_1'),
                result2 => NestedResult->new(val => 'result_2_result_2'))));
    is $deep_p->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::TYPE_FIELD()}, 'NestedResult';
    is $deep_p->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::DATA_FIELD()}->{result1}
      ->{OpenQA::Parser::TYPE_FIELD()}, 'NestedResult';
    is $deep_p->_build_tree->{generated_tests_results}->[0]->{OpenQA::Parser::DATA_FIELD()}->{result1}
      ->{OpenQA::Parser::DATA_FIELD()}->{result1}->{OpenQA::Parser::TYPE_FIELD()}, 'NestedResult'
      or diag explain $deep_p->_build_tree->{generated_tests_results}->[0];

    my $parser_nested = parser('Base');
    $parser_nested->{from_nothing} = NestedResult->new(val => 'from nothing!');
    $parser_nested->{from_nothing2} = [qw(1 2 3)];
    $parser_nested->{from_nothing3} = {1 => 2};

    $parser_nested->results(
        NestedResults->new(
            NestedResult->new(
                result1 => NestedResult->new(
                    result1 => NestedResult->new(val => '0_result_1_result_1_val'),
                    result2 => NestedResult->new(val => '0_result_1_result_2_val')
                ),
                result2 => NestedResult->new(
                    result1 => NestedResult->new(val => '0_result_2_result_1_val'),
                    result2 => NestedResult->new(val => '0_result_2_result_2_val'))
            ),
            NestedResult->new(result_1 => '1_result_1'),
            NestedResults->new(
                NestedResults->new(
                    NestedResult->new(
                        result1 => NestedResult->new(val => '2_0_0_result1_val'),
                        val => '2_0_0_val'
                    ),
                    NestedResult->new(val => '2_0_1_val'))
            ),
            NestedResult->new(
                result1 => NestedResults->new(
                    NestedResult->new(val => 'result_1_result_1'),
                    NestedResult->new(val => 'result_1_result_2'))
            ),
        ));

    my $serialized = parser("Base")->deserialize($parser_nested->serialize());
    my $serialized_tree = $serialized->_build_tree();
    is_deeply $serialized->_build_tree(), $parser_nested->_build_tree(), 'Tree are matching'
      or die diag explain $serialized;

    is $serialized->{from_nothing}->val(), 'from nothing!', 'Capable of serializing the whole object'
      or die diag explain $serialized;

    is_deeply $serialized->{from_nothing2}, [qw(1 2 3)], 'Capable of serializing the whole object'
      or die diag explain $serialized;

    is_deeply $serialized->{from_nothing3}, {1 => 2}, 'Capable of serializing the whole object'
      or die diag explain $serialized;

    ok "$serialized" ne "$parser_nested";
    is $serialized->results->get(2)->first->first->result1->val, '2_0_0_result1_val', 'Can use the objects normally';
};

sub test_junit_file {
    my $parser = shift;

    is_deeply $parser->tests->first->to_hash,
      {
        'category' => 'tests-systemd',
        'flags' => {},
        'name' => '1_running_upstream_tests',
        'script' => undef
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
    my $reported_size = $parser->write_output($resultsdir);
    my $actually_written = $resultsdir->list_tree;
    my $actually_written_count = $actually_written->size;
    my $actually_written_size = $actually_written->reduce(sub { $a + $b->stat->size }, 0);
    note "write_output wrote $actually_written_count files ($actually_written_size bytes in total)";
    is $actually_written_count, 166, '166 test outputs were written';
    is $reported_size, $actually_written_size, 'reported size matches actually written size';
    $actually_written->each(
        sub {
            fail('Output result was written correctly') unless ($_->slurp =~ /# system-out:|# running upstream test/);
        });

    my $expected_test_result = {
        dents => 0,
        details => [
            {
                _source => 'parser',
                result => 'ok',
                text => 'tests-systemd-9_post-tests_audits-1.txt',
                title => 'audit with systemd-analyze blame'
            },
            {
                _source => 'parser',
                result => 'ok',
                text => 'tests-systemd-9_post-tests_audits-2.txt',
                title => 'audit with systemd-analyze critical-chain'
            },
            {
                _source => 'parser',
                result => 'ok',
                text => 'tests-systemd-9_post-tests_audits-3.txt',
                title => 'audit with systemd-cgls'
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
            fail 'json result: filename expected to be like result-\d_.*\.json but is ' . $_
              unless $_ =~ qr/result-\d_.*\.json/;
            my $res = decode_json $_->slurp;
            is ref $res, 'HASH', 'json result: can be decoded' or diag explain $_->slurp;
            fail 'json result: exists $res->{result}' unless exists $res->{result};
            fail 'json result: !exists $res->{name}' unless !exists $res->{name};
        });

    $testdir->remove_tree;

    is_deeply $parser->results->last->TO_JSON(), $expected_test_result,
      'Expected test result match - with no include_results'
      or diag explain $parser->results->last->TO_JSON();
    return $expected_test_result;
}


sub test_xunit_file {
    my $parser = shift;
    is_deeply $parser->tests->first->to_hash,
      {
        'category' => 'xunit',
        'flags' => {},
        'name' => 'bacon',
        'script' => undef
      };
    is $parser->tests->search("name", qr/bacon/)->size, 1;

    is $parser->tests->search("name", qr/bacon/)->first()->name, 'bacon';
    is $parser->generated_tests_results->search("result", qr/ok/)->size, 7;

    is $parser->generated_tests_results->first()->properties->first->value, 'y';
    is $parser->generated_tests_results->first()->properties->last->value, 'd';

    ok $parser->generated_tests_results->first()->time;
    ok $parser->generated_tests_results->first()->errors;
    ok $parser->generated_tests_results->first()->failures;
    ok $parser->generated_tests_results->first()->tests;

    is $parser->tests->size, 11,
      'Generated 11 openQA tests results';    # 9 testsuites with all cumulative results for openQA
    is $parser->generated_tests_results->size, 11, 'Object contains 11 testsuites';

    is $parser->results->search_in_details("title", qr/bacon/)->size, 13,
      'Overall 11 testsuites, 2 tests does not have title containing bacon';
    is $parser->results->search_in_details("text", qr/bacon/)->size, 15,
      'Overall 11 testsuites, 15 tests are for bacon';
    is $parser->generated_tests_output->size, 23, "23 Outputs";

    my $resultsdir = tempdir;
    $parser->write_output($resultsdir);
    is $resultsdir->list_tree->size, 23, '23 test outputs were written';
    $resultsdir->list_tree->each(
        sub {
            fail('Output result was written correctly') unless ($_->slurp =~ /^# Test messages /);
        });

    my $expected_test_result = {

        'dents' => 0,
        'details' => [
            {
                '_source' => 'parser',
                'result' => 'ok',
                'text' => 'xunit-child_of_child_two-1.txt',
                'title' => 'child of child two test'
            }
        ],
        'result' => 'ok'

    };

    is_deeply $parser->generated_tests_results->last->TO_JSON, $expected_test_result, 'TO_JSON matches'
      or diag explain $parser->generated_tests_results->last->TO_JSON;

    my $testdir = tempdir;
    $parser->write_test_result($testdir);
    is $testdir->list_tree->size, 11, '11 test results were written' or diag explain $parser->generated_tests_results;
    $testdir->list_tree->each(
        sub {
            fail 'json result: filename expected to be like result-.*\.json but is ' . $_
              unless $_ =~ qr/result-.*\.json/;
            my $res = decode_json $_->slurp;
            is ref $res, 'HASH', 'json result: can be decoded' or diag explain $_->slurp;
            fail 'json result: exists $res->{result}' unless exists $res->{result};
            fail 'json result: result can be ok or fail but is ' . $res->{result} unless $res->{result} =~ qr/ok|fail/;
            fail 'json result: !exists $res->{name}' unless !exists $res->{name};
            fail 'json result: !exists $res->{properties}' unless !exists $res->{properties};
        });

    $testdir->remove_tree;

    is_deeply $parser->results->last->TO_JSON(), $expected_test_result,
      'Expected test result match - with no include_results'
      or diag explain $parser->results->last->TO_JSON();
    return $expected_test_result;
}

subtest junit_parse => sub {
    my $parser = OpenQA::Parser::Format::JUnit->new;

    my $junit_test_file = path($FindBin::Bin, "data")->child("junit-results.xml");

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

    $parser = OpenQA::Parser::Format::JUnit->new;

    $parser->include_results(1);
    $parser->load($junit_test_file);

    is $parser->results->size, 9,
      'Generated 9 openQA tests results';    # 9 testsuites with all cumulative results for openQA

    is_deeply $parser->results->last->TO_JSON(0), $expected_test_result, 'Test is hidden';

    $expected_test_result->{test} = {
        'category' => 'tests-systemd',
        'flags' => {},
        'name' => '9_post-tests_audits',
        'script' => 'unk'
    };

    is_deeply $parser->results->last->TO_JSON(1), $expected_test_result, 'Test is showed';

    $parser = OpenQA::Parser::Format::JUnit->new;

    $junit_test_file = path($FindBin::Bin, "data")->child("junit-results-fail.xml");

    $parser->load($junit_test_file);

    is $parser->results->first->result, 'fail', 'First testsuite fails as testcases are failing';
    is scalar @{$parser->results->first->details}, 33, '33 test cases details';
    is $_->{result}, 'fail', 'All testcases are failing' for @{$parser->results->first->details};

    $parser = OpenQA::Parser::Format::JUnit->new;

    $junit_test_file = path($FindBin::Bin, "data")->child("junit-results-output-softfail.xml");

    $parser->load($junit_test_file);

    is $parser->results->first->result, 'softfail', 'First testsuite softfails as testcases are softfailing';
    is scalar @{$parser->results->first->details}, 1, '1 test cases details';
    is $_->{result}, 'softfail', 'All testcases are softfailing' for @{$parser->results->first->details};
};

sub test_tap_file {
    my $p = shift;
    is $p->results->size, 1, 'Expected 1 results';
    $p->results->each(
        sub {
            is $_->details->[0]->{result}, 'ok', "Test has passed" or diag explain $_;
        });
}

subtest tap_parse_ok => sub {
    my $parser = OpenQA::Parser::Format::TAP->new;

    my $tap_test_file = path($FindBin::Bin, "data")->child("tap_format_example.tap");

    $parser = OpenQA::Parser::Format::TAP->new;
    $parser->load($tap_test_file);

    is $parser->results->size, 1, "File has 6 test cases";

    is $parser->results->first->result, 'passed', 'First test passes';
    is scalar @{$parser->results->first->details}, 6, '1 test cases details';

    is $parser->results->last->result, 'passed', 'Last test passes';
    is scalar @{$parser->results->last->details}, 6, '1 test cases details';

    is $_->{result}, 'ok', 'All testcases are passing' for @{$parser->results->first->details};
};

subtest tap_parse_fail => sub {
    # test other suffix and failing test
    my $tap_test_file = path($FindBin::Bin, "data")->child("tap_format_example2.tap");

    my $parser = OpenQA::Parser::Format::TAP->new;
    $parser->load($tap_test_file);

    is $parser->results->size, 1, "One test file";
    is $parser->results->first->result, 'fail', 'tests failed';

    is scalar @{$parser->results->first->details}, 2, '2 test cases details';

    is $parser->results->first->details->[0]->{result}, 'ok', 'Test 1 passed';
    is $parser->results->first->details->[1]->{result}, 'fail', 'Test 2 failed';
};

subtest tap_parse_invalid => sub {
    # test invalid TAP
    my $tap_test_file = path($FindBin::Bin, "data")->child("tap_format_example3.tap");

    my $parser = OpenQA::Parser::Format::TAP->new;

    eval { $parser->load($tap_test_file) };
    my $error = $@;

    like $error, qr{A valid TAP starts with filename.tap}, "Invalid TAP example";
};

sub test_ltp_file {
    my $p = shift;
    is $p->results->size, 6, 'Expected 6 results';
    my $i = 2;
    $p->results->each(
        sub {
            is $_->details->[0]->{_source}, 'parser';
            is $_->result, 'ok', 'Tests passed' or diag explain $_;
            ok !!$_->environment, 'Environment is present';
            ok !!$_->test, 'Test information is present';
            is $_->environment->gcc, 'gcc (SUSE Linux) 7.2.1 20170927 [gcc-7-branch revision 253227]',
              'Environment information matches';
            is $_->test->result, 'TPASS', 'subtest result is TPASS' or diag explain $_;
            is $_->test_fqn, "LTP:cpuhotplug:cpuhotplug0$i", "test_fqn matches and are different";
            $i++;
        });
    is $p->results->get(0)->environment->gcc, 'gcc (SUSE Linux) 7.2.1 20170927 [gcc-7-branch revision 253227]',
      'Environment information matches';
}

sub test_ipa_file {
    my $p = shift;
    my %names;
    is $p->results->size, 18, 'Expected 18 results' or die diag explain $p->results;
    is $p->tests->size, 18, 'Expected 18 tests' or die diag explain $p->results;

    $p->results->each(
        sub {
            ok !exists($names{$_->name}), 'Test name ' . $_->name;
            $names{$_->name} = 1;
            is $_->details->[0]->{_source}, 'parser';
            if ($_->name =~ /^test_sles_repos|test_sles_guestregister|test_sles_smt_reg|EC2_test_sles_ec2_network_01$/)
            {
                is $_->result, 'fail' or die;
            }
            elsif ($_->name =~ /^EC2_test_sles_ec2_network$/) {
                is $_->result, 'skip' or die;
            }
            else {
                is $_->result, 'ok' or die diag explain $_;
            }
        });
    is $p->extra->first->distro, 'sles', 'Sys info parsed correctly';
    is $p->extra->first->platform, 'ec2', 'Platform info parsed correctly';
}

sub test_ltp_file_v2 {
    my $p = shift;
    is $p->results->size, 4, 'Expected 4 results';
    is $p->extra->first->gcc, 'gcc (SUSE Linux) 7.2.1 20171020 [gcc-7-branch revision 253932]';
    my $i = 2;
    $p->results->each(
        sub {
            is $_->details->[0]->{_source}, 'parser';
            is $_->status, 'pass', 'Tests passed';
            ok !!$_->environment, 'Environment is present';
            ok !!$_->test, 'Test information is present';
            is $_->environment->gcc, undef;
            is $_->test->result, 'PASS', 'subtest result is PASS';
            like $_->test_fqn, qr/LTP:/, "test_fqn is there";
            $i++;
        });
}

subtest ltp_parse => sub {

    my $parser = OpenQA::Parser::Format::LTP->new;

    my $ltp_test_result_file = path($FindBin::Bin, "data")->child("ltp_test_result_format.json");

    $parser->load($ltp_test_result_file);

    test_ltp_file($parser);


    my $parser_format_v2 = OpenQA::Parser::Format::LTP->new;

    $ltp_test_result_file = path($FindBin::Bin, "data")->child("new_ltp_result_array.json");

    $parser_format_v2->load($ltp_test_result_file);

    test_ltp_file_v2($parser_format_v2);
};

sub serialize_test {
    my ($parser_name, $file, $test_function) = @_;

    subtest "Serialization test for $parser_name and $file with test $test_function" => sub {
        my $test_result_file = path($FindBin::Bin, "data")->child($file);

        # With content saved
        my $parser = $parser_name->new(include_content => 1);
        $parser->load($test_result_file);
        my $obj_content = $parser->serialize();

        my $wrote_file = tempfile();
        $wrote_file->spurt($obj_content);
        ok -e $wrote_file, 'File was written';
        ok length($wrote_file->slurp()) > 3000, 'File has content';

        my $deserialized = $parser_name->new->deserialize($wrote_file->slurp);
        ok "$deserialized" ne "$parser", "Different objects";

        $test_function->($parser);
        $test_function->($deserialized);

        is $parser->content, $test_result_file->slurp, 'Content was kept intact for original obj'
          or diag explain $deserialized->content;
        is $deserialized->content, $test_result_file->slurp, 'Content was kept intact'
          or die diag explain $deserialized->content;

        $parser = $parser_name->new(include_content => 1);
        my $saved = tempfile;
        $parser->load($test_result_file);
        is path($saved)->slurp, '', 'Empty';
        ok length(path($saved)->slurp) == 0, 'Data';
        $parser->save($saved);
        ok length(path($saved)->slurp) > 50, 'Data';
        $deserialized = $parser_name->new->from_file($saved);
        ok "$deserialized" ne "$parser", "Different objects";
        $test_function->($parser);
        $test_function->($deserialized);
        is $parser->content, $test_result_file->slurp, 'Content was kept intact for original obj'
          or diag explain $deserialized->content;
        is $deserialized->content, $test_result_file->slurp, 'Content was kept intact'
          or diag explain $deserialized->content;

        # No content saved
        $parser = $parser_name->new();
        $parser->load($test_result_file);
        $obj_content = $parser->serialize();
        $deserialized = $parser_name->new->deserialize($obj_content);
        ok "$deserialized" ne "$parser", "Different objects";
        $test_function->($parser);
        $test_function->($deserialized);
        is $parser->content, undef, 'Content is not there' or diag explain $deserialized->content;
        is $deserialized->content, undef, 'Content is not there' or diag explain $deserialized->content;

        $parser = $parser_name->new();
        $parser->load($test_result_file);
        $saved = tempfile;
        is path($saved)->slurp, '', 'Empty';
        ok length(path($saved)->slurp) == 0, 'Data';
        $parser->save($saved);
        ok length(path($saved)->slurp) > 50, 'Data';
        $deserialized = $parser_name->new->from_file($saved);
        ok "$deserialized" ne "$parser", "Different objects";
        $test_function->($parser);
        $test_function->($deserialized);
        is $parser->content, undef, 'Content is not there' or diag explain $deserialized->content;
        is $deserialized->content, undef, 'Content is not there' or diag explain $deserialized->content;

        # Json
        $parser = $parser_name->new();
        $parser->load($test_result_file);
        $obj_content = $parser->to_json();
        $deserialized = $parser_name->new()->from_json($obj_content);
        ok "$deserialized" ne "$parser", "Different objects";
        $test_function->($parser);
        $test_function->($deserialized);

        $parser = $parser_name->new();
        $parser->load($test_result_file);
        $saved = tempfile;
        ok length(path($saved)->slurp) == 0, 'Data';
        $parser->save_to_json($saved);
        ok length(path($saved)->slurp) > 50, 'Data';
        $deserialized = $parser_name->new()->from_json_file($saved);
        ok "$deserialized" ne "$parser", "Different objects";
        $test_function->($parser);
        $test_function->($deserialized);

        $parser = $parser_name->new(include_content => 1);
        $parser->load($test_result_file);
        $saved = tempfile;
        ok length(path($saved)->slurp) == 0, 'Data';
        $parser->save_to_json($saved);
        ok length(path($saved)->slurp) > 50, 'Data';
        $deserialized = $parser_name->new()->from_json_file($saved);
        ok "$deserialized" ne "$parser", "Different objects";
        $test_function->($parser);
        $test_function->($deserialized);
        is $parser->content, $test_result_file->slurp, 'Content was kept intact for original obj'
          or diag explain $deserialized->content;
        is $deserialized->content, $test_result_file->slurp, 'Content was kept intact'
          or diag explain $deserialized->content;
    };
}

subtest 'serialize/deserialize' => sub {
    serialize_test("OpenQA::Parser::Format::IPA", "ipa.json", \&test_ipa_file);
    serialize_test("OpenQA::Parser::Format::LTP", "ltp_test_result_format.json", \&test_ltp_file);
    serialize_test("OpenQA::Parser::Format::LTP", "new_ltp_result_array.json", \&test_ltp_file_v2);
    serialize_test("OpenQA::Parser::Format::JUnit", "junit-results.xml", \&test_junit_file);
    serialize_test("OpenQA::Parser::Format::XUnit", "xunit_format_example.xml", \&test_xunit_file);
    serialize_test("OpenQA::Parser::Format::TAP", "tap_format_example.tap", \&test_tap_file);
};

subtest 'Unstructured data' => sub {
    # Unstructured data can be still parsed.
    # However it will require a specific parser implementation to handle the data.
    # Then we can map results as general OpenQA::Parser::Result objects.
    my $parser = OpenQA::Parser::UnstructuredDummy->new();
    $parser->parse(join('', <DATA>));
    ok $parser->results->size == 5, 'There are some results';

    $parser->results->each(
        sub {
            ok !!$_->get('servlet-name'), 'servlet-name exists: ' . $_->get('servlet-name')->val;
            like $_->get('servlet-name')->val, qr/cofax|servlet/i, 'Name matches';
        });

    my $serialized = $parser->serialize();
    my $deserialized = OpenQA::Parser::UnstructuredDummy->new()->deserialize($serialized);

    $deserialized->results->each(
        sub {
            ok !!$_->get('servlet-name'), 'servlet-name exists - ' . $_->get('servlet-name')->val;
            like $_->get('servlet-name')->val(), qr/cofax|servlet/i, 'Name matches';

        });
    ok $deserialized->results->size == 5, 'There are some results';
    is $deserialized->results->first->get('init-param')->val->{'configGlossary:installationAt'}, 'Philadelphia, PA',
      'Nested serialization works!';

    my $init_params = $deserialized->results->get(1)->get('init-param');

    isa_ok($init_params, 'OpenQA::Parser::Result::Node');
    isa_ok($init_params->get('mailHost'), 'OpenQA::Parser::Result::Node');
    isa_ok($init_params->get('mailHost')->get('override'), 'OpenQA::Parser::Result::Node');
    is($init_params->get('mailHost')->get('override')->get('always')->val, 'yes') or die diag explain $init_params;
    is($init_params->mailHost->override->always->val, 'yes') or die diag explain $init_params;

    my $n = $deserialized->results->last->get('init-param');
    is $n->dataLogLocation()->val(), "/usr/local/tomcat/logs/dataLog.log", or die diag explain $n;

    #bool are decoded '1'/1 or '0'/0 between perl 5.18 and 5.26
    $n->val->{'betaServer'} = $n->val->{'betaServer'} ? 1 : 0;

    is_deeply $n->val,
      {
        "templatePath" => "toolstemplates/",
        "log" => 1,
        "logLocation" => "/usr/local/tomcat/logs/CofaxTools.log",
        "logMaxSize" => "",
        "dataLog" => 1,
        "dataLogLocation" => "/usr/local/tomcat/logs/dataLog.log",
        "dataLogMaxSize" => "",
        "removePageCache" => "/content/admin/remove?cache=pages&id=",
        "removeTemplateCache" => "/content/admin/remove?cache=templates&id=",
        "fileTransferFolder" => "/usr/local/tomcat/webapps/content/fileTransferFolder",
        "lookInContext" => 1,
        "adminGroupID" => 4,
        "betaServer" => 1
      },
      'Last servlet matches',
      or die diag explain $n;
};

subtest functional_interface => sub {

    use OpenQA::Parser qw(parser p);

    my $ltp = parser("LTP");
    is ref($ltp), 'OpenQA::Parser::Format::LTP', 'Parser found';

    eval { p("Doesn'tExist!"); };
    ok $@;
    like $@, qr/Parser not found!/, 'Croaked correctly';
    {
        package OpenQA::Parser::Format::Broken;    # uncoverable statement
        sub new { die 'boo' }
    }

    eval { p("Broken"); };
    ok $@;
    like $@, qr/Invalid parser supplied: boo/, 'Croaked correctly';

    my $default = p();
    ok $default->isa('OpenQA::Parser::Format::Base');

    # Supports functional interface.
    my $test_file = path($FindBin::Bin, "data")->child("new_ltp_result_array.json");
    my $parsed_res = p(LTP => $test_file);

    is $parsed_res->results->size, 4, 'Expected 4 results';
    is $parsed_res->extra->first->gcc, 'gcc (SUSE Linux) 7.2.1 20171020 [gcc-7-branch revision 253932]';

    # Keeps working as usual
    $parsed_res = p("LTP")->load($test_file);

    is $parsed_res->results->size, 4, 'Expected 4 results';
    is $parsed_res->extra->first->gcc, 'gcc (SUSE Linux) 7.2.1 20171020 [gcc-7-branch revision 253932]';

    $parsed_res = p("LTP")->parse($test_file->slurp);

    is $parsed_res->results->size, 4, 'Expected 4 results';
    is $parsed_res->extra->first->gcc, 'gcc (SUSE Linux) 7.2.1 20171020 [gcc-7-branch revision 253932]';
};

subtest dummy_search_fails => sub {

    my $parsed_res = p("Dummy");
    $parsed_res->include_results(1);
    $parsed_res->parse;
    is $parsed_res->results->size, 1, 'Expected 1 result';
    is $parsed_res->results->first->get('name')->val, 'test', 'Name of result is test';
    is $parsed_res->results->first->{test}, undef;
};


subtest xunit_parse => sub {
    my $parser = parser(XUnit => path($FindBin::Bin, "data")->child("xunit_format_example.xml"));

    my $expected_test_result = test_xunit_file($parser);
};

subtest nested_parsers => sub {
    my $join = p();

    my $parser = parser(LTP => path($FindBin::Bin, "data")->child("new_ltp_result_array.json"));
    # E.g serialize it and retrieve (normally it would be only retrieved)
    my $frozen = $parser->serialize();

    my $data = parser('LTP')->deserialize($frozen);
    $join->results()->add($data);
    my $frozen_again = $join->serialize();

    my $frozen_file = tempfile();
    $frozen_file->spurt($frozen_again);

    my $final_data = parser()->deserialize($frozen_file->slurp());
    test_ltp_file_v2($final_data->results->first);
};

done_testing;

{
    package OpenQA::Parser::Format::Dummy;    # uncoverable statement
    use Mojo::Base 'OpenQA::Parser::Format::JUnit';
    sub parse { shift->_add_result(name => 'test'); }
}

{
    package OpenQA::Parser::UnstructuredDummy;    # uncoverable statement count:2
    use Mojo::Base 'OpenQA::Parser::Format::Base';
    use Mojo::JSON 'decode_json';

    sub parse() {
        my ($self, $json) = @_;
        die "No JSON given/loaded" unless $json;
        my $decoded_json = decode_json $json;

        foreach my $res (@{$decoded_json->{'web-app'}->{servlet}}) {
            $self->_add_result($res);
            # equivalent to $self->results->add(OpenQA::Parser::Result->new($res));
            # or $self->_add_single_result($res);
        }
        $self;
    }

}

__DATA__
{
	"web-app": {
		"servlet": [
			{
				"servlet-name": "cofaxCDS",
				"servlet-class": "org.cofax.cds.CDSServlet",
				"init-param": {
					"configGlossary:installationAt": "Philadelphia, PA",
					"configGlossary:adminEmail": "ksm@pobox.com",
					"configGlossary:poweredBy": "Cofax",
					"configGlossary:poweredByIcon": "/images/cofax.gif",
					"configGlossary:staticPath": "/content/static",
					"templateProcessorClass": "org.cofax.WysiwygTemplate",
					"templateLoaderClass": "org.cofax.FilesTemplateLoader",
					"templatePath": "templates",
					"templateOverridePath": "",
					"defaultListTemplate": "listTemplate.htm",
					"defaultFileTemplate": "articleTemplate.htm",
					"useJSP": false,
					"jspListTemplate": "listTemplate.jsp",
					"jspFileTemplate": "articleTemplate.jsp",
					"cachePackageTagsTrack": 200,
					"cachePackageTagsStore": 200,
					"cachePackageTagsRefresh": 60,
					"cacheTemplatesTrack": 100,
					"cacheTemplatesStore": 50,
					"cacheTemplatesRefresh": 15,
					"cachePagesTrack": 200,
					"cachePagesStore": 100,
					"cachePagesRefresh": 10,
					"cachePagesDirtyRead": 10,
					"searchEngineListTemplate": "forSearchEnginesList.htm",
					"searchEngineFileTemplate": "forSearchEngines.htm",
					"searchEngineRobotsDb": "WEB-INF/robots.db",
					"useDataStore": true,
					"dataStoreClass": "org.cofax.SqlDataStore",
					"redirectionClass": "org.cofax.SqlRedirection",
					"dataStoreName": "cofax",
					"dataStoreDriver": "com.microsoft.jdbc.sqlserver.SQLServerDriver",
					"dataStoreUrl": "jdbc:microsoft:sqlserver://LOCALHOST:1433;DatabaseName=goon",
					"dataStoreUser": "sa",
					"dataStorePassword": "dataStoreTestQuery",
					"dataStoreTestQuery": "SET NOCOUNT ON;select test='test';",
					"dataStoreLogFile": "/usr/local/tomcat/logs/datastore.log",
					"dataStoreInitConns": 10,
					"dataStoreMaxConns": 100,
					"dataStoreConnUsageLimit": 100,
					"dataStoreLogLevel": "debug",
					"maxUrlLength": 500
				}
			},
			{
				"servlet-name": "cofaxEmail",
				"servlet-class": "org.cofax.cds.EmailServlet",
				"init-param": {
					"mailHost": {
  					"realMail": "foo@bar",
  					"override": {
        					"for": "foo@bar2",
        					"always": "yes"
            }
  				},
					"mailHostOverride": "mail2"
				}
			},
			{
				"servlet-name": "cofaxAdmin",
				"servlet-class": "org.cofax.cds.AdminServlet"
			},
			{
				"servlet-name": "fileServlet",
				"servlet-class": "org.cofax.cds.FileServlet"
			},
			{
				"servlet-name": "cofaxTools",
				"servlet-class": "org.cofax.cms.CofaxToolsServlet",
				"init-param": {
					"templatePath": "toolstemplates/",
					"log": 1,
					"logLocation": "/usr/local/tomcat/logs/CofaxTools.log",
					"logMaxSize": "",
					"dataLog": 1,
					"dataLogLocation": "/usr/local/tomcat/logs/dataLog.log",
					"dataLogMaxSize": "",
					"removePageCache": "/content/admin/remove?cache=pages&id=",
					"removeTemplateCache": "/content/admin/remove?cache=templates&id=",
					"fileTransferFolder": "/usr/local/tomcat/webapps/content/fileTransferFolder",
					"lookInContext": 1,
					"adminGroupID": 4,
					"betaServer": true
				}
			}
		],
		"servlet-mapping": {
			"cofaxCDS": "/",
			"cofaxEmail": "/cofaxutil/aemail/*",
			"cofaxAdmin": "/admin/*",
			"fileServlet": "/static/*",
			"cofaxTools": "/tools/*"
		},
		"taglib": {
			"taglib-uri": "cofax.tld",
			"taglib-location": "/WEB-INF/tlds/cofax.tld"
		}
	}
}
