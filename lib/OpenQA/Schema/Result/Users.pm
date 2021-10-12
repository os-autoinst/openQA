# Copyright 2014-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::Users;

use strict;
use warnings;

use base 'DBIx::Class::Core';

use URI::Escape 'uri_escape';
use Digest::MD5 'md5_hex';

__PACKAGE__->table('users');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    username => {
        data_type => 'text',
    },
    provider => {
        data_type => 'text',
        default_value => '',
    },
    email => {
        data_type => 'text',
        is_nullable => 1,
    },
    fullname => {
        data_type => 'text',
        is_nullable => 1,
    },
    nickname => {
        data_type => 'text',
        is_nullable => 1,
    },
    is_operator => {
        data_type => 'integer',
        is_boolean => 1,
        false_id => ['0', '-1'],
        default_value => '0',
    },
    is_admin => {
        data_type => 'integer',
        is_boolean => 1,
        false_id => ['0', '-1'],
        default_value => '0',
    },
    feature_version => {
        data_type => 'integer',
        default_value => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(api_keys => 'OpenQA::Schema::Result::ApiKeys', 'user_id');
__PACKAGE__->has_many(
    developer_sessions => 'OpenQA::Schema::Result::DeveloperSessions',
    'user_id', {cascade_delete => 1});
__PACKAGE__->add_unique_constraint([qw(username provider)]);

sub name {
    my ($self) = @_;

    if (!$self->{_name}) {
        $self->{_name} = $self->nickname;
        if (!$self->{_name}) {
            $self->{_name} = $self->username;
        }
    }
    return $self->{_name};
}

sub gravatar {
    my ($self, $size) = @_;
    $size //= 40;

    if (my $email = $self->email) {
        return "//www.gravatar.com/avatar/" . md5_hex(lc $email) . "?d=wavatar&s=$size";
    }
    else {
        return "//www.gravatar.com/avatar?s=$size";
    }
}


1;
