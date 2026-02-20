package CMakeLocal::CLI;

use strict;
use warnings;
use Exporter 'import';

use CMakeLocal::Util qw(normalize_onoff);

our @EXPORT_OK = qw(
    parse_cli
);

sub parse_cli {
    my ($argv, $cli_defs) = @_;

    my %values;
    my %flags;

    while (@$argv) {
        my $arg = shift @$argv;

        next unless $arg =~ /^--/;

        my ($option, $inline_value) = split(/=/, $arg, 2);

        if ($option eq "--help") {
            $flags{help} = 1;
            next;
        }
        if ($option eq "--install") {
            $flags{install} = 1;
            next;
        }

        my $def = $cli_defs->{$option};
        die "Unknown option: $option\n" unless $def;

        my $id = $def->{id};
        my $type = $def->{type} // "";

        if ($type eq "bool_onoff") {
            my $val = defined $inline_value ? $inline_value : (shift(@$argv) // "ON");
            $values{$id} = normalize_onoff($val);
        }
        else {
            my $val = defined $inline_value ? $inline_value : shift(@$argv);
            die "Option $option requires a value\n" unless defined $val;
            $values{$id} = $val;
        }
    }

    return (\%values, \%flags);
}

1;
