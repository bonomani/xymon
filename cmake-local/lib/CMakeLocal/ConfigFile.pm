package CMakeLocal::ConfigFile;

use strict;
use warnings;
use Exporter 'import';

use CMakeLocal::Config qw(read_simple_conf);
use CMakeLocal::Util qw(normalize_onoff);

our @EXPORT_OK = qw(
    load_config
    config_bool
    config_value
);

sub load_config {
    my ($path) = @_;
    return {} unless defined $path && -f $path;
    return { read_simple_conf($path) };
}

sub config_bool {
    my ($cfg, $name, $default) = @_;

    return $default unless defined $cfg && ref $cfg eq "HASH";
    return $default unless exists $cfg->{$name};

    my $value = $cfg->{$name};
    return $default unless defined $value && $value ne "";

    my $normalized = normalize_onoff($value);
    return $default unless defined $normalized;

    return $normalized eq "ON";
}

sub config_value {
    my ($cfg, $name, $default) = @_;

    return $default unless defined $cfg && ref $cfg eq "HASH";
    return $default unless exists $cfg->{$name};

    my $value = $cfg->{$name};
    return $default unless defined $value && $value ne "";

    return $value;
}

1;
