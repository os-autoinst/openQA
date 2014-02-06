package Schema::Result::Jobs;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('jobs');
__PACKAGE__->add_columns(qw/ id name state_id priority result worker_id start_date finish_date /);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(settings => 'Schema::Result::JobSettings', 'job_id');
__PACKAGE__->belongs_to(state => 'Schema::Result::JobState', 'state_id');
__PACKAGE__->belongs_to(worker => 'Schema::Result::Workers', 'worker_id');

1;
