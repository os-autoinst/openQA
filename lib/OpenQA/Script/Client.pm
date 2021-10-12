# Copyright 2018-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Script::Client;

use Mojo::Base -strict, -signatures;

use Exporter 'import';
use Mojo::JSON;    # booleans
use Data::Dump 'dd';
use Mojo::URL;
use Scalar::Util ();
use OpenQA::Client;
use OpenQA::YAML qw(dump_yaml load_yaml);
# use UTF-8 on all streams to prevent problems when reading/writing unicode
use open ":std", ":encoding(UTF-8)";


our @EXPORT = qw(
  handle_result
  prepend_api_base
  url_from_host
  run
);

our $apibase = '/api/v1';

sub handle_result ($options, $res) {
    my $rescode = $res->code // 0;
    my $message = "{no message}";
    $message = $res->{error}->{message} if ($rescode != 200 && $res->{error} && $res->{error}->{message});

    if ($rescode >= 200 && $rescode <= 299) {
        printf(STDERR "%s - %s\n", $rescode, $message) if $rescode > 200;
        my $content_type = $res->headers->content_type;
        my $json = $res->json;
        my $body = $res->body;
        if ($options->{'json-output'}) {
            if ($content_type =~ m{text/yaml}) {
                my $yaml = load_yaml(string => $body);
                print Cpanel::JSON::XS->new->pretty->encode($yaml);
            }
            else {
                print Cpanel::JSON::XS->new->allow_nonref->pretty->encode($json);
            }
        }
        elsif ($options->{'yaml-output'}) {
            if ($content_type =~ m{text/yaml}) {
                # avoid messy prompt when missing final linebreak
                $body .= "\n" unless $body =~ m/\n\z/;
                print $body;
            }
            else {
                print dump_yaml(string => $json);
            }
        }
        else {
            dd($content_type =~ m{text/yaml} ? load_yaml(string => $body) : $json);
        }
        return $json;
    }

    printf(STDERR "ERROR: %s - %s\n", $rescode, $message);
    if ($res->body) {
        if ($options->{json}) {
            print Cpanel::JSON::XS->new->pretty->encode($res->json);
        }
        else {
            dd($res->json || $res->body);
        }
    }
    return undef;
}

# prepend the API-base if the specified path is relative
sub prepend_api_base ($path) {
    $path = join('/', $apibase, $path) if $path !~ m/^\//;
    return $path;
}

sub url_from_host ($host) {
    return Mojo::URL->new($host) if $host =~ '/';
    my $url = Mojo::URL->new();
    $url->host($host);
    $url->scheme($host eq 'localhost' ? 'http' : 'https');
    return $url;
}

sub run ($options, $operation, @args) {
    $options->{host} ||= 'localhost';
    $apibase = $options->{apibase} if $options->{apibase};
    my $path = prepend_api_base($operation);
    my $method = 'get';
    my %params;

    if ($options->{params}) {
        local $/;
        open(my $fh, '<', $options->{params});
        my $info = Cpanel::JSON::XS->new->relaxed->decode(<$fh>);
        close $fh;
        %params = %{$info};
    }

    for my $arg (@ARGV) {
        if ($arg =~ /^(?:get|post|delete|put)$/i) {
            $method = lc $arg;
        }
        elsif ($arg =~ /^([[:alnum:]_\[\]\.]+)=(.+)$/s) {
            $params{$1} = $2;
        }
    }

    my $url = url_from_host($options->{host});
    $url->path($path);

    if ($options->{form}) {
        my %form;
        for (keys %params) {
            if (/(\S+)\.(\S+)/) {
                $form{$1}{$2} = $params{$_};
            }
            else {
                $form{$_} = $params{$_};
            }
        }
        %params = %form;
    }
    else {
        $url->query([%params]) if %params;
    }

    my $accept = $options->{accept} || '';
    my %accept = (
        yaml => 'text/yaml',
        json => 'application/json',
    );
    # We accept any content-type by default
    my $accept_header = $accept{$accept} || '*/*';

    my $client
      = OpenQA::Client->new(apikey => $options->{apikey}, apisecret => $options->{apisecret}, api => $url->host);

    return handle_result($options, $client->$method($url, form => \%params)->res) if $options->{form};
    return handle_result($options,
        $client->$method($url, {'Content-Type' => 'application/json'} => $options->{'json-data'})->res)
      if $options->{'json-data'};

    # Either the user wants to call a command or wants to interact with
    # the rest api directly.
    if ($options->{archive}) {
        my $res;
        $options->{path} = $path;
        $options->{url} = $url;
        $options->{params} = \%params;
        $options->{params2} = @ARGV;
        eval { $res = $client->archive->run($options) };
        die "ERROR: $@ \n", $@ if $@;
        exit(0);
    }
    elsif ($operation eq 'jobs/overview/restart') {
        $url->path(prepend_api_base('jobs/overview'));
        my $relevant_jobs = handle_result($options, $client->get($url)->res);
        my @job_ids = map { $_->{id} } @$relevant_jobs;
        $url->path(prepend_api_base('jobs/restart'));
        $url->query(Mojo::Parameters->new);
        $url->query(jobs => \@job_ids);
        print("$url\n");
        return handle_result($options, $client->post($url, {Accept => $accept_header})->res);
    }
    else {
        return handle_result($options, $client->$method($url, {Accept => $accept_header})->res);
    }
}

1;
