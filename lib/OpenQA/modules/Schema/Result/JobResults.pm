package Schema::Result::JobResults;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('job_results');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
        is_auto_increment => 1,
    },
    name => {
        data_type => 'text',
    }
   );

__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(jobs => 'Schema::Result::Jobs', 'result_id');

1;
