#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;

BEGIN {
    require Cwd;
    require File::Basename;

    my $bin_dir    = Cwd::abs_path($FindBin::Bin);                  # cmake-local/bin
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

use CMakeLocal::Util qw(
    normalize_onoff
);

use CMakeLocal::Presets qw(
    get_preset_binary_dir
);

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------

my $build_dir        = $ENV{BUILD_DIR}        or die "BUILD_DIR is required\n";
my $non_interactive  = $ENV{NON_INTERACTIVE}  // 0;
my $build_install    = $ENV{BUILD_INSTALL}    // 1;
my $destdir_override = $ENV{DESTDIR_OVERRIDE} // "";
my $use_ci_configure = $ENV{USE_CI_CONFIGURE} // 0;
my $preset_override  = $ENV{PRESET_OVERRIDE}  // "";
my $root_dir         = $ENV{ROOT_DIR}         // $PROJECT_ROOT;

# ------------------------------------------------------------
# CI preset override (via lib, path-safe)
# ------------------------------------------------------------

if ($use_ci_configure eq "1" && $preset_override ne "") {

    my $preset_build_dir = get_preset_binary_dir(
        $preset_override,
        standard   => "$PROJECT_ROOT/CMakePresets.json",
        source_dir => $PROJECT_ROOT,
    );

    if (defined $preset_build_dir && $preset_build_dir ne "") {
        $build_dir = $preset_build_dir;
    }
}

# ------------------------------------------------------------
# Install phase
# ------------------------------------------------------------

exit 0 unless $build_install eq "1";

if ($destdir_override ne "") {
    $ENV{DESTDIR} = $destdir_override;
}

my @install_cmd = ("cmake", "--install", $build_dir);

if ($non_interactive ne "1") {

    print "Install now? [y/N]: ";
    chomp(my $ans = <STDIN>);

    if (normalize_onoff($ans) eq "ON") {
        system(@install_cmd) == 0
            or die "Install failed\n";
    }
    else {
        print "Install skipped.\n";
    }

}
else {
    system(@install_cmd) == 0
        or die "Install failed\n";
}

exit 0;
