package CMakeLocal::Rules;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    extract_fields
    extract_cli_defs
);

sub extract_fields {
    my ($rules) = @_;

    my (%fields, %preset_fields);

    for my $section (@{ $rules->{sections} // [] }) {
        if ($section->{id} && $section->{id} eq "preset_identity") {
            for my $f (@{ $section->{fields} // [] }) {
                $preset_fields{$f->{id}} = $f;
            }
            next;
        }

        for my $f (@{ $section->{fields} // [] }) {
            $fields{$f->{id}} = $f;
        }
    }

    return (\%fields, \%preset_fields);
}

sub extract_cli_defs {
    my ($rules) = @_;

    my %cli_defs;

    for my $section (@{ $rules->{sections} // [] }) {
        for my $f (@{ $section->{fields} // [] }) {
            if ($f->{cli} && $f->{cli}{option}) {
                $cli_defs{$f->{cli}{option}} = $f;
            }
        }
    }

    for my $g (@{ $rules->{cli_globals} // [] }) {
        if ($g->{cli} && $g->{cli}{option}) {
            $cli_defs{$g->{cli}{option}} = $g;
        }
    }

    return %cli_defs;
}

1;

