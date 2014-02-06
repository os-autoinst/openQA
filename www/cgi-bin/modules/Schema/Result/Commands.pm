package Schema::Result::Commands;
use base qw/DBIx::Class::Core/;

__PACKAGE__->table('commands');
__PACKAGE__->add_columns(qw/ id worker_id command /);
__PACKAGE__->set_primary_key('id');
__PACKAGE__->belongs_to(worker => 'Schema::Result::Workers', 'worker_id');

1;
