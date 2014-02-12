package Schema::Result::JobStates;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('job_states');
__PACKAGE__->add_columns(
    id => {
        data_type => 'integer',
    },
    name => {
        data_type => 'text',
    }
   );

__PACKAGE__->set_primary_key('id');
__PACKAGE__->has_many(jobs => 'Schema::Result::Jobs', 'state_id');

# TODO
#INSERT INTO "job_states" VALUES(1,'scheduled');
#INSERT INTO "job_states" VALUES(2,'running');
#INSERT INTO "job_states" VALUES(3,'cancelled');
#INSERT INTO "job_states" VALUES(4,'waiting');
#INSERT INTO "job_states" VALUES(5,'done');

1;
