package CMakeLocal::Resolve;

use strict;
use warnings;
use Exporter 'import';

use CMakeLocal::Util qw(normalize_onoff);

our @EXPORT_OK = qw(
    eval_default_if_strict
    eval_default_if_preview
    resolve_all
);

# ------------------------------------------------------------
# Strict evaluation: refuse missing dependencies
# ------------------------------------------------------------

sub eval_default_if_strict {
    my ($expr, $vals) = @_;

    my $check = $expr;
    $check =~ s/'[^']*'//g;

    my @deps = ($check =~ /([A-Z0-9_]+)/g);
    for my $d (@deps) {
        return undef
            unless exists $vals->{$d}
            && defined $vals->{$d}
            && $vals->{$d} ne "";
    }

    my $e = $expr;
    $e =~ s{([A-Z0-9_]+)}{
        exists $vals->{$1} ? "'" . $vals->{$1} . "'" : $1
    }ge;
    $e =~ s/\s*\+\s*/./g;

    return eval $e;
}

# ------------------------------------------------------------
# Preview evaluation: tolerate missing values (UX / editor)
# ------------------------------------------------------------

sub eval_default_if_preview {
    my ($expr, @contexts) = @_;

    my %vars;
    for my $ctx (@contexts) {
        next unless $ctx && ref $ctx eq 'HASH';
        %vars = (%vars, %$ctx);
    }

    my $e = $expr;
    $e =~ s{([A-Z0-9_]+)}{
        defined $vars{$1} ? "'" . $vars{$1} . "'" : "''"
    }ge;
    $e =~ s/\s*\+\s*/./g;

    return eval $e;
}

# ------------------------------------------------------------
# resolve_all(): strict resolution loop
# ------------------------------------------------------------

sub resolve_all {
    my ($fields, $input) = @_;

    my %resolved = %$input;
    my $changed  = 1;

    while ($changed) {
        $changed = 0;

        for my $id (keys %$fields) {
            next if exists $resolved{$id}
                 && defined $resolved{$id}
                 && $resolved{$id} ne "";

            my $f = $fields->{$id};

            if (exists $f->{default}) {
                $resolved{$id} = $f->{default};
                $changed = 1;
            }
            elsif (exists $f->{default_by_variant}) {
                my $v = $resolved{VARIANT};
                if (defined $v && exists $f->{default_by_variant}{$v}) {
                    $resolved{$id} = $f->{default_by_variant}{$v};
                    $changed = 1;
                }
            }
            elsif (exists $f->{default_if}) {
                my $val = eval_default_if_strict($f->{default_if}, \%resolved);
                if (defined $val && $val ne "") {
                    $resolved{$id} = $val;
                    $changed = 1;
                }
            }

            if (($f->{type} // "") eq "bool_onoff"
                && exists $resolved{$id}) {
                $resolved{$id} = normalize_onoff($resolved{$id});
            }
        }
    }

    return %resolved;
}

1;

