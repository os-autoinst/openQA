# Copyright (C) 2015 SUSE LLC
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


package OpenQA::WebAPI::Controller::Admin::AuditLog;
use strict;
use parent 'Mojolicious::Controller';
use Fcntl qw/SEEK_CUR SEEK_END/;

sub index {
    my $self = shift;
    #my $assets = $self->db->resultset("AuditLog")->search(undef, {order_by => 'id', prefetch => 'user', limit => 100});

    my $auditfh;
    return unless open($auditfh, '<', $self->app->config->{logging}->{audit_log});
    my $log;
    my $size = -s $self->app->config->{logging}->{audit_log};
    if ($size > 10 * 1024 && seek $auditfh, -10 * 1024, SEEK_END) {
        # Discard one (probably) partial line
        my $dummy = <$auditfh>;
    }
    while (defined(my $l = <$auditfh>)) {
        $log .= $l;
    }
    seek $auditfh, 0, SEEK_CUR;
    close($auditfh);
    $self->stash('log' => $log);
    $self->render('admin/audit_log/index');
}

sub ajax {
    # follow audit log
}

1;
