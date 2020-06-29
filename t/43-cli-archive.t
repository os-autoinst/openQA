# Copyright (C) 2020 SUSE LLC
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

use Mojo::Base -strict;

use FindBin;
use lib "$FindBin::Bin/lib";

use Test::More;
use Capture::Tiny qw(capture_stdout);
use Mojo::Server::Daemon;
use Mojo::File qw(tempdir tempfile);
use OpenQA::CLI;
use OpenQA::CLI::archive;
use OpenQA::Test::Case;

OpenQA::Test::Case->new->init_data(fixtures_glob => '01-jobs.pl 03-users.pl 05-job_modules.pl');

# Mock WebAPI with extra test routes
my $daemon = Mojo::Server::Daemon->new(listen => ['http://127.0.0.1']);
my $app    = $daemon->build_app('OpenQA::WebAPI');
$app->log->level('error');
my $port = $daemon->start->ports->[0];
my $host = "http://127.0.0.1:$port";

# Default options for mock server
my @host = ('--host', $host);

# Default options for authentication tests
my @auth = ('--apikey', 'ARTHURKEY01', '--apisecret', 'EXCALIBUR', @host);

my $cli     = OpenQA::CLI->new;
my $archive = OpenQA::CLI::archive->new;
my $dir     = tempdir("/tmp/$FindBin::Script-XXXX");

subtest 'Help' => sub {
    my ($stdout, @result) = capture_stdout sub { $cli->run('help', 'archive') };
    like $stdout, qr/Usage: openqa-cli archive/, 'help';
};

subtest 'Archive job' => sub {
    my $target = $dir->child('archive')->make_path;
    my ($stdout, $stderr, @result) = capture_stdout sub { $cli->run('archive', @host, 99937, $target->to_string) };

    like $stdout, qr/Downloading test details and screenshots to $target/,         'downloading details';
    like $stdout, qr/Saved details for .+details-isosize.json/,                    'saved details';
    like $stdout, qr/Saved details for .+details-installer_desktopselection.json/, 'saved details';
    like $stdout, qr/Saved details for .+details-shutdown.json/,                   'saved details';

    like $stdout, qr/Downloading video.ogv/,                                           'downloading video';
    like $stdout, qr/Asset video.ogv sucessfully downloaded and moved to .+video.ogv/, 'moved video';

    like $stdout, qr/Downloading serial0.txt/,                                             'downloading serial0.txt';
    like $stdout, qr/Asset serial0.txt sucessfully downloaded and moved to .+serial0.txt/, 'moved serial0.txt';

    like $stdout, qr/Downloading autoinst-log.txt/, 'downloading autoinst-log.txt';
    like $stdout, qr/Asset autoinst-log.txt sucessfully downloaded and moved to .+autoinst-log.txt/,
      'moved autoinst-log.txt';

    like $stdout, qr/Downloading ulogs/, 'downloading ulogs';

    my $results = $target->child('testresults');
    ok -d $results, 'testresults directory exists';
    ok -f $results->child('details-isosize.json'),                    'details-isosize.json exists';
    ok -f $results->child('details-installer_desktopselection.json'), 'details-installer_desktopselection.json exists';
    ok -f $results->child('details-shutdown.json'),                   'details-shutdown.json exists';
    ok -f $results->child('video.ogv'),                               'video.ogv exists';
    ok -f $results->child('serial0.txt'),                             'serial0.txt exists';
    ok -f $results->child('autoinst-log.txt'),                        'autoinst-log.txt exists';

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
    ok -f $results->child('autoinst-log.txt'),     'autoinst-log.txt exists';
    ok -d $results->child('thumbnails'),           'thumbnails';

    $target = tempdir;
    ($stdout, $stderr, @result)
      = capture_stdout sub { $cli->run('archive', @host, '--with-thumbnails', 99937, $target->to_string) };
    like $stdout, qr/Downloading test details and screenshots to $target/, 'downloading details';
    $results = $target->child('testresults');
    ok -d $results, 'testresults directory exists';
    ok -f $results->child('details-isosize.json'), 'details-isosize.json exists';
    ok -f $results->child('autoinst-log.txt'),     'autoinst-log.txt exists';
    ok -d $results->child('thumbnails'),           'thumbnails';
};

done_testing();
