package CMakeLocal::ConfigMenu;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(render_menu render_menu_with_footer render_menu_line menu_title);

sub _print_header {
    my ($title) = @_;
    print "$title\n" if defined $title && $title ne '';
}

sub render_menu {
    my ($title, $entries, $options) = @_;
    $options //= {};
    _print_header($title);

    for my $idx (0 .. $#$entries) {
        printf "  %d) %s\n", $idx + 1, $entries->[$idx];
    }
    my @extra = @{ $options->{extra} // [] };
    if ($options->{back}) {
        push @extra, '  b) Back'
            unless grep { $_ eq '  b) Back' } @extra;
    }
    print "  $_\n" for @extra;
    if (my $hint = $options->{hint}) {
        print "\n$hint\n";
    }
    print "\n" if $options->{spacing} // 0;
}

sub render_menu_with_footer {
    my ($title, $entries, $footer, $options) = @_;
    render_menu($title, $entries, $options);
    if ($footer) {
        print "$_\n" for @$footer;
    }
}

sub render_menu_line {
    my ($title, $entries, $options) = @_;
    render_menu($title, $entries, $options);
}

sub menu_title {
    my @parts = grep { defined $_ && $_ ne '' } @_;
    return "" unless @parts;
    @parts = map { s/^\s+|\s+$//gr } @parts;
    return join(" ", map { "<$_>" } @parts);
}

1;
