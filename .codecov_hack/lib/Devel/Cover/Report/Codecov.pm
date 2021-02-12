# Temporary workaround for https://github.com/codecov/codecov-perl/pull/42
# Remove once the fix has made it into openSUSE:Factory
package Devel::Cover::Report::Codecov;
use strict;
use warnings;
use utf8;
our $VERSION = '0.25';

use URI;
use Furl;
use JSON::XS;
use Sub::Retry;

use Module::Find;
useall 'Devel::Cover::Report::Codecov::Service';


our $API_ENDPOINT = 'https://codecov.io/upload/v2';
our $RETRY_TIMES  = 5;
our $RETRY_DELAY  = 1;                                # sec

sub report {
    my ($pkg, $db, $options) = @_;

    my @services = get_services($pkg);
    my ($service) = grep { $_->detect } @services;
    die 'unknown service. could not get configuration' unless $service;

    my $query = get_query($service);
    my $url   = get_request_url($API_ENDPOINT, $query);
    my $json  = get_codecov_json($options->{file}, $db);
    my $res   = send_report($url, $json);

    if ($res->{ok}) {
        print $res->{message} . "\n";
    }

    else {
        die $res->{message} . "\n";
    }
}

sub get_services {
    my $pkg = shift;

    my @services = findallmod "${pkg}::Service";
    return
      sort { defined $a->can('fallback') && $a->fallback ? 1 : defined $b->can('fallback') && $b->fallback ? -1 : 0 }
      @services;
}

sub get_file_lines {
    my ($file) = @_;

    my $lines = 0;

    open my $fp, '<', $file;
    $lines++ while <$fp>;
    close $fp;

    return $lines;
}

sub get_file_coverage {
    my ($filepath, $db) = @_;

    my $realpath   = get_file_realpath($filepath);
    my $lines      = get_file_lines($realpath);
    my $file       = $db->cover->file($filepath);
    my $statements = $file->statement;
    my $branches   = $file->branch;
    my @coverage   = (undef);

    for (my $i = 1; $i <= $lines; $i++) {
        my $statement = $statements->location($i);
        my $branch    = defined $branches ? $branches->location($i) : undef;
        push @coverage, get_line_coverage($statement, $branch);
    }

    return $realpath => \@coverage;
}

sub get_line_coverage {
    my ($statement, $branch) = @_;

    # If all branches covered or uncoverable, report as all covered
    return $branch->[0]->total . '/' . $branch->[0]->total   if $branch && !$branch->[0]->error;
    return $branch->[0]->covered . '/' . $branch->[0]->total if $branch;
    return $statement unless $statement;
    return if $statement->[0]->uncoverable;
    return $statement->[0]->covered;
}

sub get_file_realpath {
    my $file = shift;

    if (-d 'blib') {
        my $realpath = $file;
        $realpath =~ s/blib\/lib/lib/;

        return $realpath if -f $realpath;
    }

    return $file;
}

sub get_codecov_json {
    my ($files, $db) = @_;

    my %coverages = map { get_file_coverage($_, $db) } @$files;
    my $request   = {coverage => \%coverages, messages => {}};

    return encode_json($request);
}

sub get_request_url {
    my ($base_url, $query) = @_;

    my $url = URI->new($base_url);
    $url->query_form($query);

    return $url->canonical;
}

sub get_query {
    my ($service) = @_;

    my $query = $service->configuration;

    if (defined $ENV{CODECOV_TOKEN}) {
        $query->{token} = lc $ENV{CODECOV_TOKEN};
    }

    return $query;
}

sub send_report {
    my ($url, $json) = @_;

    my $n_times = $RETRY_TIMES > 0 ? $RETRY_TIMES : 1;

    # evaluate in list context
    my $result;
    {
        no warnings 'void';
        [retry $n_times, $RETRY_DELAY, sub { $result = send_report_once($url, $json) }, sub { $_[0]->{ok} ? 0 : 1 }];
    };

    return $result;
}

sub send_report_once {
    my ($url, $json) = @_;

    my $furl    = Furl->new;
    my $headers = [];
    my $res     = $furl->post($url, $headers, $json);

    my ($message, $ok);

    if ($res->code == 200) {
        my $content = decode_json($res->content);

        $ok      = 1;
        $message = <<EOF;
@{[$res->code]} @{[$res->message]}
@{[$content->{message}]}
@{[$content->{url}]}
EOF
    }

    else {
        $ok      = 0;
        $message = <<EOF;
@{[$res->code]} @{[$res->message]}
@{[$res->content]}
EOF
    }

    return {
        ok      => $ok,
        message => $message,
    };
}

1;
__END__

=encoding utf-8

=head1 NAME

Devel::Cover::Report::Codecov - Backend for Codecov reporting of coverage statistics

=head1 SYNOPSIS

    $ cover -report codecov

=head1 DESCRIPTION

Devel::Cover::Report::Codecov is coverage reporter for L<Codecov|https://codecov.io>.

=head2 CI Companies Supported

Many CI services supported.
You must set CODECOV_TOKEN environment variables if you don't use Travis CI, Circle CI and AppVeyor.

=over 4

=item * L<Travis CI|https://travis-ci.org/>

=item * L<Circle CI|https://circleci.com/>

=item * L<Codeship|https://codeship.com/>

=item * L<Semaphore|https://semaphoreci.com/>

=item * L<drone.io|https://drone.io/>

=item * L<AppVeyor|https://www.appveyor.com/>

=item * L<Wercker|https://wercker.com/>

=item * L<Shippable|https://www.shippable.com/>

=item * L<GitLab CI|https://about.gitlab.com/gitlab-ci/>

=item * L<Bitrise|https://www.bitrise.io/>

=back

There are example Codecov CI settings in L<example-perl|https://github.com/codecov/example-perl>.

=head1 SEE ALSO

=over 4

=item * L<Devel::Cover>

=back

=head1 LICENSE

The MIT License (MIT)

Copyright (c) 2015-2019 Pine Mizune

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

=head1 AUTHOR

Pine Mizune E<lt>pinemz@gmail.comE<gt>

=cut
