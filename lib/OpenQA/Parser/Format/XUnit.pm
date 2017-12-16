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

package OpenQA::Parser::Format::XUnit;

use Mojo::Base 'OpenQA::Parser::Format::JUnit';
use Carp qw(croak confess);

sub _add_single_result { shift->results->add(OpenQA::Parser::Result::XUnit->new(@_)) }

sub addproperty { shift->{properties}->add(OpenQA::Parser::Result::XUnit::Property->new(shift)) }

sub parse {
    my ($self, $xml) = @_;
    confess "No XML given/loaded" unless $xml;
    $self->_dom(Mojo::DOM->new->xml(1)->parse($xml));

    my $dom = $self->_dom();
    my @tests;
    my %t_names;
    my $i = 1;
    for my $ts ($dom->find('testsuite')->each) {

        my $result      = {};
        my $ts_category = exists $ts->{classname} ? $ts->{classname} : 'xunit';
        my $ts_name     = exists $ts->{name} ? $ts->{name} : 'unkn';

        # We add support for this optional field :)
        my $ts_generator_script = exists $ts->{script} ? $ts->{script} : undef;

        $result->{errors}   = exists $ts->{errors}   ? $ts->{errors} : undef;
        $result->{tests}    = exists $ts->{tests}    ? $ts->{tests}  : undef;
        $result->{failures} = exists $ts->{failures} ? $ts->{errors} : undef;
        $result->{time}     = exists $ts->{time}     ? $ts->{time}   : undef;


        $ts_category =~ s/[^A-Za-z0-9._-]/_/g;
        $ts_category =~ s/\..*$//;
        $ts_name =~ s/\..*$//;
        $ts_name =~ s/[^A-Za-z0-9._-]/_/g;
        $ts_name =~ s/^[^.]*\.//;
        $ts_name =~ s/\./_/;
        if (exists $ts->{id} && $ts->{id} =~ /^[0-9]+$/) {
            # make sure that the name is unique
            # prepend numeric $ts->{id}, start counting from 1
            $ts_name = ($ts->{id} + 1) . '_' . $ts_name;
        }
        $ts_name .= "_${i}" if $t_names{$ts_name};
        $t_names{$ts_name}++;
        $self->_add_test(
            {
                flags    => {},
                category => $ts_category,
                name     => $ts_name,
                script   => $ts_generator_script,
            });

        my $ts_result = 'ok';
        $ts_result = 'fail' if ($ts->{failures} && $ts->{failures} > 0) || ($ts->{errors} && $ts->{errors} > 0);
        $result->{result}     = $ts_result;
        $result->{dents}      = 0;
        $result->{properties} = OpenQA::Parser::Results->new;
        my $num = 1;
        $ts->find('property')->each(sub { addproperty($result, {name => $_->{name}, value => $_->{value}}) });

        $ts->children('testcase')->each(
            sub {
                my $tc        = shift;
                my $tc_result = 'ok';
                $tc_result = 'fail'
                  if ($tc->{failures} && $tc->{failures} > 0) || ($tc->{errors} && $tc->{errors} > 0);

                my $text_fn = "$ts_category-$ts_name-$num.txt";
                my $content = "# Test messages ";
                $content .= "# $tc->{name}\n" if $tc->{name};

                for my $out ($tc->children('skipped, passed, error, failure')->each) {
                    $content .= "# " . $out->tag . ": \n\n";
                    $content .= $out->{message} . "\n" if $out->{message};
                    $content .= $out->text . "\n";
                }

                push @{$result->{details}}, {text => $text_fn, title => $tc->{name}, result => $tc_result};

                $self->_add_output(
                    {
                        file    => $text_fn,
                        content => $content
                    });
                $num++;
            });

        $result->{name} = $ts_name;
        $self->_add_result(%$result);
        $i++;
    }
    $self;
}

# Schema
{
    package OpenQA::Parser::Result::XUnit;
    use Mojo::Base 'OpenQA::Parser::Result::OpenQA';
    has properties => sub { OpenQA::Parser::Result::XUnit::PropertyResults->new };

    has [qw(errors tests failures time)];

    sub to_hash {
        {
            properties => $_[0]->properties()->to_array,
            errors     => $_[0]->errors(),
            tests      => $_[0]->tests(),
            failures   => $_[0]->failures(),
            time       => $_[0]->time(),
            result     => $_[0]->result(),
            dents      => $_[0]->dents(),
            details    => $_[0]->details(),
            name       => $_[0]->name(),
            (test => $_[0]->test ? $_[0]->test->to_hash : undef) x !!($_[1])};
    }

}

{
    package OpenQA::Parser::Result::XUnit::PropertyResults;
    use Mojo::Base 'OpenQA::Parser::Results';

    # Declare the mapping of the results collection
    our $of = 'OpenQA::Parser::Result::XUnit::Property';

    # or either override the constructor explictly and map the arguments:
    #sub new {
    #    return shift->SUPER::new(map{OpenQA::Parser::Result::XUnit::Property->new($_)} @_);
    #}
}

{
    package OpenQA::Parser::Result::XUnit::Property;
    use Mojo::Base 'OpenQA::Parser::Result';

    has [qw(name value)];
}

!!42;
