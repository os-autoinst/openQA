package Schema::Result::Workers;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('workers');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
    },
    host => {
        data_type => 'text',
    },
    instance => {
        data_type => 'integer',
    },
    backend => {
        data_type => 'text',
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
__PACKAGE__->add_unique_constraint(constraint_name => [ qw/host instance/ ]);
__PACKAGE__->has_many(jobs => 'Schema::Result::Jobs', 'worker_id');
__PACKAGE__->has_many(commands => 'Schema::Result::Commands', 'worker_id');

# TODO
# INSERT INTO workers (id, t_created) VALUES(0, datetime('now'));

1;
