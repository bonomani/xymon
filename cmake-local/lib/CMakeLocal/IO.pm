package CMakeLocal::IO;

use strict;
use warnings;
use Exporter 'import';

use JSON::PP;
use File::Slurp qw(read_file write_file);

our @EXPORT_OK = qw(
    load_json_file
    save_json_file
);

sub load_json_file {
    my ($file) = @_;

    return undef unless defined $file && -f $file;

    my $raw = read_file($file, binmode => ":raw");
    die "ERROR: $file is empty\n"
        unless defined $raw && length $raw;

    my $data = eval { decode_json($raw) };
    die "ERROR: invalid JSON in $file\n$@\n" if $@;

    return $data;
}

sub save_json_file {
    my ($file, $data) = @_;

    die "ERROR: output file not defined\n"
        unless defined $file;

    write_file(
        $file,
        JSON::PP->new->pretty->canonical->encode($data)
    );

    return 1;
}

1;
