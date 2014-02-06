package Schema::Result::JobSettings;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('job_settings');
__PACKAGE__->add_columns(qw/ id job_id key value /);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(job => 'Schema::Result::Jobs', 'job_id');

1;
