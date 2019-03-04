# Copyright (C) 2018 SUSE LLC
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

package OpenQA::WebAPI::GruJob;
use Mojo::Base 'Minion::Job';

use OpenQA::Utils 'log_error';

sub execute {
    my $self = shift;

    my $info   = $self->info;
    my $gru_id = $info->{notes}{gru_id};
    my $ttl    = $info->{notes}{ttl};

    my $elapsed = time - $info->{created};
    if (defined $ttl && $elapsed > $ttl) {
        my $ttl_error = 'TTL Expired';
        $self->fail({error => $ttl_error});
        $self->_fail_gru($gru_id => $ttl_error) if $gru_id;
        return undef;
    }

    my ($buffer, $err);
    {
        open my $handle, '>', \$buffer;
        local *STDERR = $handle;
        local *STDOUT = $handle;
        $err = $self->SUPER::execute;
    };

    $info = $self->info;
    my $state = $info->{state};
    if ($state eq 'failed' || defined $err) {
        $err //= $info->{result};
        log_error("Gru command issue: $err");
        $self->fail({defined $buffer ? (output => $buffer) : (), error => $err});
        $self->_fail_gru($gru_id => $err) if $gru_id;
    }
    elsif ($state eq 'active' || $state eq 'finished') {
        $self->finish(defined $buffer ? $buffer : 'Job successfully executed');
        $self->_delete_gru($gru_id) if $gru_id;
    }

    return undef;
}

sub _delete_gru {
    my ($self, $id) = @_;
    my $gru = $self->minion->app->db->resultset('GruTasks')->find($id);
    $gru->delete() if $gru;
}

sub _fail_gru {
    my ($self, $id, $reason) = @_;
    my $gru = $self->minion->app->db->resultset('GruTasks')->find($id);
    $gru->fail($reason) if $gru;
}

1;

=encoding utf8

=head1 NAME

OpenQA::WebAPI::GruJob - A Gru Job

=head1 SYNOPSIS

    use OpenQA::WebAPI::GruJob;

=head1 DESCRIPTION

L<OpenQA::WebAPI::GruJob> is a subclass of L<Minion::Job> used by
L<OpenQA::WebAPI::Plugin::Gru> that adds Gru metadata handling and TTL support.

=cut
