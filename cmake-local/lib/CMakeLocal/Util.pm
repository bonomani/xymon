package CMakeLocal::Util;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    normalize_onoff
    validate_enum
);

sub normalize_onoff {
    my ($v) = @_;
    return undef unless defined $v;

    $v = uc $v;

    return "ON"  if $v =~ /^(ON|YES|Y|TRUE|1)$/;
    return "OFF" if $v =~ /^(OFF|NO|N|FALSE|0)$/;

    return $v;
}

sub validate_enum {
    my ($value, $enum) = @_;
    for (@$enum) {
        return $value if $_ eq $value;
    }
    die "Invalid value '$value' (allowed: " . join(", ", @$enum) . ")\n";
}

1;

