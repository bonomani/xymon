#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;

BEGIN {
    require Cwd;
    require File::Basename;

    my $bin_dir    = Cwd::abs_path($FindBin::Bin);                     # cmake-local/bin
    my $cmakelocal = Cwd::abs_path(File::Basename::dirname($bin_dir)); # cmake-local
    my $lib_dir    = "$cmakelocal/lib";

    unshift @INC, $lib_dir;
}

use CMakeLocal::Bootstrap qw($PROJECT_ROOT);

# ------------------------------------------------------------
# Resolve paths (NEVER rely on cwd)
# ------------------------------------------------------------

# ------------------------------------------------------------
# Imports
# ------------------------------------------------------------

use CMakeLocal::Config qw(
    write_simple_conf
);

use CMakeLocal::ConfigTemplate qw(
    default_config_content
);

# ------------------------------------------------------------
# Target config file (project root)
# ------------------------------------------------------------

my $conf_file = "$PROJECT_ROOT/cmake-local.conf";

my $force = grep { $_ eq "--force" } @ARGV;

if (-e $conf_file && !$force) {
    die "cmake-local.conf already exists (use --force to overwrite)\n";
}

my $content = default_config_content();

write_simple_conf($conf_file, $content);

print "cmake-local.conf created at $conf_file\n";
exit 0;
