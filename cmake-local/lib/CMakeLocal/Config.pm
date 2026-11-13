package CMakeLocal::Config;

use strict;
use warnings;
use Exporter 'import';
use POSIX qw(strftime);

our @EXPORT_OK = qw(
    read_simple_conf
    write_simple_conf
    prompt
    now_timestamp
);

sub now_timestamp {
    return strftime("%Y-%m-%dT%H:%M:%S", localtime);
}

sub read_simple_conf {
    my ($file) = @_;
    my %cfg;

    open my $fh, "<", $file or die "Cannot read $file: $!\n";
    while (<$fh>) {
        chomp;
        next if /^\s*#/ || /^\s*$/;
        s/\s+#.*$//;
        if (/^\s*([A-Za-z0-9_]+)\s*=\s*(.+)\s*$/) {
            $cfg{$1} = $2;
        }
    }
    close $fh;

    return %cfg;
}

sub write_simple_conf {
    my ($file, $content) = @_;
    open my $fh, ">", $file or die "Cannot write $file: $!\n";
    print $fh $content;
    close $fh or die "Failed to write $file: $!\n";
}

sub prompt {
    my ($label, $current) = @_;
    print "$label [$current]: ";
    my $in = <STDIN>;
    chomp $in;
    return $in eq "" ? $current : $in;
}

1;

