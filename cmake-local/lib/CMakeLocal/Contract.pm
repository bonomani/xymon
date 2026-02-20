package CMakeLocal::Contract;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    validate_contract
);

sub validate_contract {
    my ($rules, $vals) = @_;

    my %allow_ci = map { $_ => 1 }
        @{ $rules->{resolution}{ci_allowed_missing} // [] };

    my @missing;

    for my $id (@{ $rules->{resolution}{required} }) {
        next if exists $vals->{$id}
             && defined $vals->{$id}
             && $vals->{$id} ne "";
        next if ($ENV{CI} && $allow_ci{$id});
        push @missing, $id;
    }

    die "Missing required values: " . join(", ", @missing) . "\n"
        if @missing;
}

1;

