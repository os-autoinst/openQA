package WebQA::Rpc;
use Mojo::Base 'Mojolicious::Controller';
use JSON;

sub call {
    my $self = shift;

    my $clientclass;
    for my $i (qw/JSON::RPC::Legacy::Client JSON::RPC::Client/) {
        eval "use $i;";
        $clientclass = $i unless $@;
    }
    die $@ unless $clientclass;

    my $url = $self->param('url') || '';
    my $method = $self->param('method') || '';
    my $json = $self->param('params') || 0;
    my $params;
    my $callobj;
    if ($json) {
        $params = decode_json($json);
        $callobj = { method => $method, params => $params };
    } else {
        $callobj = { method => $method };
    }

    my $client = new $clientclass;
    my $ret = $client->call($url, $callobj);
    $self->render(json => $ret->{'jsontext'});;
}

1;
