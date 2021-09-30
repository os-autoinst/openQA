# Copyright 2020 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib", "$FindBin::Bin/../external/os-autoinst-common/lib";

use Test::More;
use Capture::Tiny qw(capture_stdout);
use Mojo::Server::Daemon;
use Mojo::File qw(tempdir tempfile);
use OpenQA::CLI;
use OpenQA::CLI::archive;
use OpenQA::Test::Case;
use OpenQA::Test::TimeLimit '10';

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');

# Mock WebAPI with extra test routes
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

# Default options for mock server
my @host = ('--host', $host);

# Default options for authentication tests
my @auth = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', @host);

my $cli = OpenQA::CLI->new;
my $archive = OpenQA::CLI::archive->new;
my $dir = tempdir("/tmp/$FindBin::Script-XXXX");

subtest 'Help' => sub {
    my ($stdout, @result) = capture_stdout sub { $cli->run('help', 'archive') };
    like $stdout, qr/Usage: openqa-cli archive/, 'help';
};

subtest 'Unknown options' => sub {
    my $archive = OpenQA::CLI::archive->new;
    my $buffer = '';
    {
        open my $handle, '>', \$buffer;
        local *STDERR = $handle;
        eval { $archive->run('--unknown') };
        like $@, qr/Usage: openqa-cli archive/, 'unknown option';
    }
    like $buffer, qr/Unknown option: unknown/, 'right output';
};

subtest 'Defaults' => sub {
    my $archive = OpenQA::CLI::archive->new;
    is $archive->apibase, '/api/v1', 'apibase';
    is $archive->apikey, undef, 'no apikey';
    is $archive->apisecret, undef, 'no apisecret';
    is $archive->host, 'http://localhost', 'host';
};

subtest 'Host' => sub {
    my $archive = OpenQA::CLI::archive->new;
    eval { $archive->run('--host', 'openqa.example.com') };
    like $@, qr/Usage: openqa-cli archive/, 'usage';
    is $archive->host, 'https://openqa.example.com', 'host';

    eval { $archive->run('--host', 'http://openqa.example.com') };
    like $@, qr/Usage: openqa-cli archive/, 'usage';
    is $archive->host, 'http://openqa.example.com', 'host';

    eval { $archive->run('--osd') };
    like $@, qr/Usage: openqa-cli archive/, 'usage';
    is $archive->host, 'http://openqa.suse.de', 'host';

    eval { $archive->run('--o3') };
    like $@, qr/Usage: openqa-cli archive/, 'usage';
    is $archive->host, 'https://openqa.opensuse.org', 'host';

    eval { $archive->run(@host) };
    like $@, qr/Usage: openqa-cli archive/, 'usage';
    is $archive->host, $host, 'host';
};

subtest 'API' => sub {
    my $archive = OpenQA::CLI::archive->new;
    eval { $archive->run('--apibase', '/foo/bar') };
    like $@, qr/Usage: openqa-cli archive/, 'usage';
    is $archive->apibase, '/foo/bar', 'apibase';

    eval { $archive->run(@auth) };
    like $@, qr/Usage: openqa-cli archive/, 'usage';
    is $archive->apikey, 'ARTHURKEY01', 'apikey';
    is $archive->apisecret, 'EXCALIBUR', 'apisecret';
};

subtest 'Archive job' => sub {
    eval { $cli->run('archive') };
    like $@, qr/Usage: openqa-cli archive/, 'usage';

    eval { $cli->run('archive', 99937) };
    like $@, qr/Usage: openqa-cli archive/, 'usage';

    eval { $cli->run('archive', @host) };
    like $@, qr/Usage: openqa-cli archive/, 'usage';

    eval { $cli->run('archive', @host, 99937) };
    like $@, qr/Usage: openqa-cli archive/, 'usage';

    my $target = $dir->child('archive')->make_path;
    my ($stdout, $stderr, @result) = capture_stdout sub { $cli->run('archive', @host, 99937, $target->to_string) };

    like $stdout, qr/Downloading test details and screenshots to $target/, 'downloading details';
    like $stdout, qr/Saved details for .+details-isosize.json/, 'saved details';
    like $stdout, qr/Saved details for .+details-installer_desktopselection.json/, 'saved details';
    like $stdout, qr/Saved details for .+details-shutdown.json/, 'saved details';

    like $stdout, qr/Downloading video.ogv/, 'downloading video';
    like $stdout, qr/Asset video.ogv successfully downloaded and moved to .+video.ogv/, 'moved video';

    like $stdout, qr/Downloading serial0.txt/, 'downloading serial0.txt';
    like $stdout, qr/Asset serial0.txt successfully downloaded and moved to .+serial0.txt/, 'moved serial0.txt';

    like $stdout, qr/Downloading autoinst-log.txt/, 'downloading autoinst-log.txt';
    like $stdout, qr/Asset autoinst-log.txt successfully downloaded and moved to .+autoinst-log.txt/,
      'moved autoinst-log.txt';

    like $stdout, qr/Downloading ulogs/, 'downloading ulogs';

    my $results = $target->child('testresults');
    ok -d $results, 'testresults directory exists';
    ok -f $results->child('details-isosize.json'), 'details-isosize.json exists';
    ok -f $results->child('details-installer_desktopselection.json'), 'details-installer_desktopselection.json exists';
    ok -f $results->child('details-shutdown.json'), 'details-shutdown.json exists';
    ok -f $results->child('video.ogv'), 'video.ogv exists';
    ok -f $results->child('serial0.txt'), 'serial0.txt exists';
    ok -f $results->child('autoinst-log.txt'), 'autoinst-log.txt exists';

    ok !-e $results->child('thumbnails'), 'no thumbnails';
};

subtest 'Archive job with thumbnails' => sub {
    my $target = $dir->child('archive-with-thumbnails')->make_path;
    my ($stdout, $stderr, @result)
      = capture_stdout sub { $cli->run('archive', @host, '-t', 99937, $target->to_string) };
    like $stdout, qr/Downloading test details and screenshots to $target/, 'downloading details';
    my $results = $target->child('testresults');
    ok -d $results, 'testresults directory exists';
    ok -f $results->child('details-isosize.json'), 'details-isosize.json exists';
    ok -f $results->child('autoinst-log.txt'), 'autoinst-log.txt exists';
    ok -d $results->child('thumbnails'), 'thumbnails';

    $target = tempdir;
    ($stdout, $stderr, @result)
      = capture_stdout sub { $cli->run('archive', @host, '--with-thumbnails', 99937, $target->to_string) };
    like $stdout, qr/Downloading test details and screenshots to $target/, 'downloading details';
    $results = $target->child('testresults');
    ok -d $results, 'testresults directory exists';
    ok -f $results->child('details-isosize.json'), 'details-isosize.json exists';
    ok -f $results->child('autoinst-log.txt'), 'autoinst-log.txt exists';
    ok -d $results->child('thumbnails'), 'thumbnails';
};

done_testing();
