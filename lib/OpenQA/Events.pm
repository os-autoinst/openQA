package OpenQA::Events;
use Mojo::Base 'Mojo::EventEmitter';

sub singleton { state $events = shift->SUPER::new }

1;
