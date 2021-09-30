package OpenQA::WebAPI::Plugin::HashedParams;
use Mojo::Base 'Mojolicious::Plugin';

our $VERSION = '0.04';

## no critic

sub register {
    my ($plugin, $app) = @_;

    $app->helper(
        hparams => sub {
            my ($self, @permit) = @_;

            if (!$self->stash('hparams')) {
                my $hprms = $self->req->params->to_hash;
                my $index = 0;
                my @array;

                foreach my $p (keys %$hprms) {
                    my $key = $p;
                    my $val = $hprms->{$p};
                    $val =~ s/\\/\\\\/g;
                    $val =~ s/\'/\\\'/g;

                    $key =~ s/[^\]\[0-9a-zA-Z_\+]//g;
                    $key =~ s/\[{2,}/\[/g;
                    $key =~ s/\]{2,}/\]/g;
                    $key =~ s/\\//g;
                    $key =~ s/\'//g;

                    my @list;
                    foreach my $n (split /[\[\]]/, $key) {
                        push @list, $n if length($n) > 0;
                    }

                    map $array[$index] .= "{'$list[$_]'}", 0 .. $#list;

                    $array[$index] .= " = '$val';";
                    $index++;
                }

                my $code = 'my $h = {};';
                map { $code .= "\$h->$_" } @array;
                $code .= '$h;';

                my $ret = eval $code;

                if ($@) {
                    $self->stash(hparams => {});
                    $self->stash(hparams_error => $@);
                    return $self->stash('hparams');
                }

                if (keys %$ret) {
                    if (@permit) {
                        foreach my $k (keys %$ret) {
                            delete $ret->{$k} if grep(/\Q$k/, @permit);
                        }
                    }

                    $self->stash(hparams => $ret);
                }
            }
            else {
                $self->stash(hparams => {});
            }
            return $self->stash('hparams');
        });
}

1;

__END__

=encoding utf8

=head1 NAME

Mojolicious::Plugin::HashedParams - Transformation request parameters into a hash and multi-hash

=head1 SYNOPSIS

  plugin 'HashedParams';

  # Transmit params:
  /route?message[body]=PerlOrDie&message[task][id]=32
    or
  <input type="text" name="message[task][id]" value="32"> 

  get '/route' => sub {
    my $self = shift;
    # you can also use permit parameters
    $self->hparams( qw(message) );
    # return all parameters in the hash
    $self->hparams();
  };

=head1 AUTHOR

Grishkovelli L<grishkovelli@gmail.com>

=head1 Git

L<https://github.com/grishkovelli/Mojolicious-Plugin-HashedParams>

=head1 COPYRIGHT

Copyright 2013, Grishkovelli.

This library is free software; you can redistribute it and/or modify it under the same terms as Perl itself.

=cut
