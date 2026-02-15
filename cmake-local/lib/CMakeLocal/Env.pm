package CMakeLocal::Env;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(
    export_env
);

sub export_env {
    my (%vars) = @_;
    for my $k (keys %vars) {
        $ENV{$k} = $vars{$k} if defined $vars{$k};
    }
}

1;

