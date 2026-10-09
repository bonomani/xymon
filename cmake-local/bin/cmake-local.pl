#!/usr/bin/env perl
use strict;
use warnings;
use FindBin;
use File::Spec::Functions qw(catfile);

BEGIN {
    require Cwd;
    require File::Basename;

    my $bin_dir    = Cwd::abs_path($FindBin::Bin);
    my $cmakelocal = Cwd::abs_path(File::Basename::dirname($bin_dir));
    my $lib_dir    = "$cmakelocal/lib";

    unshift @INC, $lib_dir;
}

use CMakeLocal::Bootstrap qw($BIN_DIR);

my %commands = (
    setup       => "cmake-local-setup.pl",
    build       => "cmake-local-build.pl",
    install     => "cmake-local-install.pl",
    config      => "cmake-local-config.pl",
    "config-init" => "cmake-local-config-init.pl",
    presets     => "cmake-presets-editor.pl",
);

sub usage {
    print <<'EOF';
Usage: cmake-local.pl [command] [args...]

Commands:
  setup        run the exploratory setup/build/install flow (default)
  build        run cmake configure + build (cmake-local-build.pl)
  install      install the current build tree (cmake-local-install.pl)
  config       edit cmake-local.conf interactively
  config-init  create or refresh cmake-local.conf from the template
  presets      open the user preset editor (operates on CMakePresets.user.json)
  help         show this message

If no command is supplied, `setup` is assumed. Remaining arguments are
forwarded to the invoked helper.

The `setup` command accepts the `--install` flag when you want to build
and install immediately (e.g. `cmake-local.sh setup --install`).
EOF
}

my $cmd = shift @ARGV // "setup";
if (defined $cmd && $cmd =~ /^-/) {
    unshift @ARGV, $cmd;
    $cmd = "setup";
}

if ($cmd =~ /^(?:help|-h|--help)$/) {
    usage();
    exit 0;
}

my $helper = $commands{$cmd};

unless ($helper) {
    if (defined $cmd && $cmd =~ /^-/) {
        warn "Flags such as '$cmd' must go with the `setup` command (e.g. \"cmake-local.sh setup $cmd\").\n";
    }
    else {
        warn "Unknown command: $cmd\n";
    }
    usage();
    exit 1;
}

my $helper_path = catfile($BIN_DIR, $helper);

unless (-e $helper_path) {
    die "Helper not found: $helper_path\n";
}

exec {$helper_path} ($helper_path, @ARGV)
    or die "Failed to exec $helper_path: $!\n";
