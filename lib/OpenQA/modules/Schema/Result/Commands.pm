package Schema::Result::Commands;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('commands');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
    },
    command => {
        data_type => 'text',
    },
    t_processed => {
        data_type => 'timestamp',
        is_nullable => 1
    },
    worker_id => {
        data_type => 'integer',
    },
    t_created => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_updated => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
);

__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(worker => 'Schema::Result::Workers', 'worker_id');

1;
