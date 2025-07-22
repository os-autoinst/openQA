# Copyright 2020-2021 SUSE LLC
# SPDX-License-Identifier: GPL-2.0-or-later

package OpenQA::CLI;
use Mojo::Base 'Mojolicious::Commands', -signatures;
use Mojo::Util qw(getopt encode);
use YAML::PP;
use FindBin '$RealBin';

has hint => <<EOF;

See 'openqa-cli COMMAND --help' for more information on a specific command.
EOF
has message => sub { OpenQA::CLI->_help() };
has namespaces => sub { ['OpenQA::CLI'] };

my $specfile = "$RealBin/../public/openqa-cli.yaml";
# packaged location
$specfile = "$RealBin/../client/openqa-cli.yaml" unless -f $specfile;

my $app_spec;
sub _get_global_options { $app_spec->{options} }

sub _get_options ($name) { $app_spec->{subcommands}->{$name}->{options}; }

sub run ($self, @args) {
    $app_spec = YAML::PP::LoadFile($specfile);
    return $self->SUPER::run(@args);
}

sub get_opt ($type, $args, $p, $result) {
    my $opts = $type eq 'global' ? _get_global_options() : _get_options($type);
    my %getopt;
    for my $option (@$opts) {
        my ($spec, $name);
        if (ref $option) {
            $name = $option->{name};
            $spec = _option_hash_to_spec($option);
        }
        else {
            $spec = $option =~ s/ .*//rs;
            ($name) = $spec =~ m/^([\w-]+)/;
        }
        $getopt{$spec} = \$result->{$name};
    }
    getopt $args, $p, %getopt;
}

sub _help ($self, $name = undef) {
    my $help = '';
    my $global_opts = _print_options('Options (for all commands):', _get_global_options());
    if ($name) {
        my $cmd = $app_spec->{subcommands}->{$name};
        $help .= "$cmd->{description}\n" if $cmd->{description};
        $help .= $global_opts;
        $help .= _print_options("Options for $name:", _get_options($name));
    }
    else {
        $help = "$global_opts\n";
    }
    return encode 'UTF-8' => $help;
}

sub _print_options ($label, $options) {
    my @rows;
    my @getopts;
    for my $option (@$options) {
        my ($spec, $desc);
        my $getopt = '';
        if (ref $option) {
            $spec = _option_hash_to_spec($option);
            $desc = $option->{summary};
        }
        else {
            ($spec, $desc) = split / +--/, $option;
        }
        push @getopts, [$spec, $desc =~ s/\s+/ /gr];
    }
    require Getopt::Long::Descriptive;
    my (undef, $usage) = Getopt::Long::Descriptive::describe_options('', @getopts);
    return $label . $usage;
}

sub _option_hash_to_spec ($opt) {
    my $name = $opt->{name};
    my $spec = $name;
    my $aliases = $opt->{aliases};
    $spec .= '|' . join '|', @{$opt->{aliases}} if $opt->{aliases};
    $spec .= '=s' if $opt->{type} // 'string' ne 'flag';
    return $spec;
}

1;
