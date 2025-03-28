# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Git::MaintenanceOutage;
use Mojo::Base -strict, -signatures;
use Mojo::File 'path';

# Remove or rename these "constants" in favor of a dynamic path
use constant MAX_DURATION_SECONDS => 1800;

use constant {
    SKIP => 'SKIP',
    FAIL => 'FAIL',
};

sub _state_file ($app) {
    path($ENV{OPENQA_GIT_SERVER_MAINTENANCE_FILE} // ($app->config->{global}->{cache_dir} // '/var/lib/openqa/cache')
          . ($ENV{OPENQA_GIT_SERVER_MAINTENANCE_FILE} ? '' : '/gitlab_maintenance.lock'));
}

sub remove_state_file ($app) { _state_file($app)->remove }

sub decide_outcome ($app) {
    my $file = _state_file($app);
    unless (-f $file) {
        $file->touch;
        return SKIP;
    }
    my $file_age = time - _state_file($app)->stat->mtime;
    return ($file_age >= ($ENV{OPENQA_GIT_SERVER_MAINTENANCE_DURATION} || MAX_DURATION_SECONDS)) ? FAIL : SKIP;
}

1;
