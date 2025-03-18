# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Git::ServerAvailability;
use Mojo::Base -strict, -signatures;
use Mojo::File qw(path);
use Time::Seconds qw(ONE_HOUR);
use OpenQA::Utils qw(prjdir);
use Exporter qw(import);

our @EXPORT_OK = qw(report_server_unavailable report_server_available SKIP FAIL);

use constant MAX_DURATION_SECONDS => ($ENV{OPENQA_GIT_SERVER_OUTAGE_DURATION} || (ONE_HOUR / 2));

use constant {
    SKIP => 'SKIP',
    FAIL => 'FAIL',
};

sub _state_file ($app, $server_name) {
    return path(($ENV{OPENQA_GIT_SERVER_OUTAGE_FILE} // prjdir . '/git_server_outage') . ".$server_name.flag");
}

sub report_server_available ($app, $server_name) {
    _state_file($app, $server_name)->remove;
}

sub report_server_unavailable ($app, $server_name) {
    my $file = _state_file($app, $server_name);
    my $stat = $file->stat;
    unless (defined $stat) {
        $file->dirname->make_path;
        $file->touch;
        return SKIP;
    }
    my $file_age = time - $stat->mtime;
    return ($file_age >= MAX_DURATION_SECONDS) ? FAIL : SKIP;
}

1;
