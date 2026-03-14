package DBIx::Class::Timestamps;

use Mojo::Base 'DBIx::Class', -signatures;
use DateTime;
use Exporter 'import';

our @EXPORT_OK = qw(now);

sub add_timestamps ($self) {

    $self->load_components(qw(InflateColumn::DateTime DynamicDefault));

    $self->add_columns(
        t_created => {
            data_type => 'timestamp',
            dynamic_default_on_create => 'now'
        },
        t_updated => {
            data_type => 'timestamp',
            dynamic_default_on_create => 'now',
            dynamic_default_on_update => 'now'
        },
    );
}

sub now ($self = undef) {
    DateTime->now(time_zone => 'UTC');
}

1;
