#!/usr/bin/env perl
use strict;
use warnings;
use Test::More tests => 4;
use FindBin qw($Bin);
use lib "$Bin/../lib";
use CMakeLocal::ConfigMenu qw(render_menu menu_title);

sub capture_render_menu {
    my ($title, $entries, $opts) = @_;
    local *STDOUT;
    my $output = '';
    open my $out, '>', \$output;
    local *STDOUT = $out;
    render_menu($title, $entries, $opts);
    return $output;
}

is(menu_title('Config', 'Editor'), '<Config> <Editor>', 'menu_title hides empty segments');

{
    my $output = capture_render_menu(menu_title('Test', 'Back'), ['one'], { back => 1 });
    like($output, qr/  b\) Back/, 'render_menu prints b) Back when requested');
}

{
    my $output = capture_render_menu(menu_title('Extras'), ['one'], { extra => ['  x) extra'], back => 1 });
    like($output, qr/  x\) extra/, 'render_menu preserves extra entries');
    like($output, qr/  b\) Back/, 'render_menu still appends b) Back when extras exist');
}
