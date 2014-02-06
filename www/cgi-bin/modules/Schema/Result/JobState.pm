package Schema::Result::JobState;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('job_state');
__PACKAGE__->add_columns(qw/ id name /);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(jobs => 'Schema::Result::Jobs', 'state_id');

1;
