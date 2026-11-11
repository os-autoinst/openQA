# Copyright SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::Schema::Result::SshKeys;
use Mojo::Base 'DBIx::Class::Core', -signatures;

use Mojo::Util 'trim';
use Digest::SHA qw(sha256);
use MIME::Base64 qw(decode_base64 encode_base64);

__PACKAGE__->table('ssh_keys');
__PACKAGE__->load_components(qw(InflateColumn::DateTime Timestamps));
__PACKAGE__->add_columns(
    id => {
        data_type => 'bigint',
        is_auto_increment => 1,
    },
    user_id => {
        data_type => 'bigint',
        is_foreign_key => 1,
    },
    title => {
        data_type => 'text',
    },
    # public key stored as OpenSSH formated string
    public_key => {
        data_type => 'text',
    },
    fingerprint => {
        data_type => 'text',
    },
    last_used => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_expiration => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);
__PACKAGE__->add_timestamps;
__PACKAGE__->set_primary_key('id');
__PACKAGE__->add_unique_constraint([qw(fingerprint)]);
__PACKAGE__->belongs_to(user => 'OpenQA::Schema::Result::Users', 'user_id');

sub new ($class, $attrs) {
    $attrs->{title} = trim($attrs->{title} // '');
    $attrs->{public_key} = trim($attrs->{public_key} // '');
    $attrs->{fingerprint} = OpenQA::Schema::Result::SshKeys::fingerprint_for($attrs->{public_key});
    my $new = $class->next::method($attrs);
    return $new;
}

# check that the public key looks like a valid single-line OpenSSH key
sub is_valid_public_key ($self) {
    my $key = $self->public_key // '';
    return $key =~ qr{^ssh-(?:rsa|ed25519|ecdsa|ssh-dss)\s+[A-Za-z0-9+/=]+(\s+\S+)?$};
}

# alias for backwards compatibility
sub pubic_key ($self) { $self->public_key }

sub fingerprint_for ($public_key) {
    my ($type, $blob) = split /\s+/, $public_key // '';
    return '' unless $blob;
    return 'SHA256:' . encode_base64(sha256(decode_base64($blob)), '');
}

1;
