# Copyright (C) 2015 SUSE Linux Products GmbH
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

package OpenQA::Worker::Pool;
use strict;
use warnings;

use Fcntl;
use File::Path qw/make_path remove_tree/;

use OpenQA::Worker::Common qw/$nocleanup $pooldir/;

use base qw/Exporter/;
our (@EXPORT_OK);
@EXPORT_OK = qw/lockit clean_pool/;

sub lockit(){
    if (!-e $pooldir) {
        make_path($pooldir);
    }
    chdir $pooldir || die "cannot change directory to $pooldir: $!\n";
    open(my $lockfd, '>>', '.locked') or die "cannot open lock file: $!\n";
    unless (fcntl($lockfd, F_SETLK, pack('ssqql', F_WRLCK, 0, 0, 0, $$))) {
        die "$pooldir already locked\n";
    }
    $lockfd->autoflush(1);
    truncate($lockfd, 0);
    print $lockfd "$$\n";
    return $lockfd;
}

sub clean_pool(){
    return if $nocleanup;
    if (-e "$pooldir/qemu.pid") {
        print "QEMU should be dead - WASUP?\n";
        exit(1);
    }
    for my $file (<$pooldir/*>) {
        if (-d $file) {
            remove_tree($file);
        }
        else {
            unlink $file;
        }
    }
}
