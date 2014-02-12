package Schema::Result::Jobs;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('jobs');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
    },
    name => {
        data_type => 'text',
        is_nullable => 1,
    },
    state_id => {
        data_type => 'integer',
    },
    priority => {
        data_type => 'integer',
    },
    result => {
        data_type => 'text',
        is_nullable => 1,
    },
    worker_id => {
        data_type => 'integer',
    },
    t_started => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_finished => {
        data_type => 'timestamp',
        is_nullable => 1,
    },

    t_created => {
        data_type => 'timestamp',
        is_nullable => 1,
    },
    t_updated => {
        data_type => 'timestamp',
    },
);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(settings => 'Schema::Result::JobSettings', 'job_id');
__PACKAGE__->belongs_to(state => 'Schema::Result::JobStates', 'state_id');
__PACKAGE__->belongs_to(worker => 'Schema::Result::Workers', 'worker_id');

__PACKAGE__->add_unique_constraint(constraint_name => [ qw/name/ ]);


1;
