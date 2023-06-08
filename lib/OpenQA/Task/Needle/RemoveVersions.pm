# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Task::Needle::RemoveVersions;
use Mojo::Base 'Mojolicious::Plugin', -signatures;

use File::Find;
use File::stat;

my $minimum_retention_time;

sub register ($self, $app, $job) {
    $minimum_retention_time = ($app->config->{'scm git'}->{minimum_needle_retention_time} // 30) * 60;
    $app->minion->add_task(remove_needle_versions => sub ($job) { _remove_needle_versions($app, $job) });
}

sub _remove_needle_versions ($app, $job) {
    return $job->finish({error => 'Another job to remove needle versions is running. Try again later.'})
      unless my $guard = $app->minion->guard('limit_needle_versions_task', 7200);

    my $needle_versions_path = "/tmp/needle_dirs";
    return unless -d $needle_versions_path;
    # Remove all temporary needles which haven't been accessed in time period specified in config
    find(\&wanted, $needle_versions_path);
    return;
}

sub wanted () {
    my $filepath = $File::Find::name;
    return unless -f $filepath;
    my $now = time;
    my $atime = stat($filepath)->atime;
    if (($now - $atime) > $minimum_retention_time) {
        unlink($filepath);
    }
}

1;
