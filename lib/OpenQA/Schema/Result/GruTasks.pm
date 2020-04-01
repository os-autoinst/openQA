# Copyright (C) 2015-2019 SUSE LLC
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

package OpenQA::Schema::Result::GruTasks;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use Mojo::JSON qw(decode_json encode_json);
use OpenQA::Parser::Result::OpenQA;
use OpenQA::Parser::Result::Test;

__PACKAGE__->table('gru_tasks');
__PACKAGE__->load_components(qw(InflateColumn::DateTime FilterColumn Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type         => 'integer',
        is_auto_increment => 1,
    },
    taskname => {
        data_type   => 'text',
        is_nullable => 0,
    },
    args => {
        data_type   => 'text',
        is_nullable => 0,
    },
    run_at => {
        data_type   => 'datetime',
        is_nullable => 0,
    },
    priority => {
        data_type   => 'integer',
        is_nullable => 0,
        default     => 0
    });
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');

__PACKAGE__->has_many(jobs => 'OpenQA::Schema::Result::GruDependencies', 'gru_task_id');

__PACKAGE__->filter_column(
    args => {
        filter_to_storage   => 'encode_json_to_db',
        filter_from_storage => 'decode_json_from_db',
    });

sub sqlt_deploy_hook {
    my ($self, $sqlt_table) = @_;

    $sqlt_table->add_index(name => 'gru_tasks_run_at_reversed', fields => 'run_at DESC');
}

sub decode_json_from_db {
    my $ret = decode_json($_[1]);
    return $ret->{_} if ref($ret) eq 'HASH' && defined $ret->{_};
    return $ret;
}

sub encode_json_to_db {
    my $args = $_[1];
    if (!ref($args)) {
        $args = {'_' => $args};
    }
    encode_json($args);
}

sub fail {
    my ($self, $reason) = @_;
    $reason //= 'Unknown';
    my $deps        = $self->jobs->search;
    my $detail_text = 'Minion-GRU.txt';

    my $result = OpenQA::Parser::Result::OpenQA->new(
        details => [{text => $detail_text, title => 'GRU'}],
        name    => 'background_process',
        result  => 'fail',
        test    => OpenQA::Parser::Result::Test->new(name => 'GRU', category => 'background_task'));
    my $output
      = OpenQA::Parser::Result::Output->new(file => $detail_text, content => "Gru job failed\nReason: $reason");

    while (my $d = $deps->next) {
        $d->job->custom_module($result => $output);
        $d->job->done(result => OpenQA::Jobs::Constants::INCOMPLETE());
        $d->delete();
    }

    $self->delete();
}

1;
