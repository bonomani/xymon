#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;

BEGIN {
    require Cwd;
    require File::Basename;

    my $bin_dir    = Cwd::abs_path($FindBin::Bin);                 # cmake-local/bin
    my $cmakelocal = Cwd::abs_path(File::Basename::dirname($bin_dir)); # cmake-local
    my $lib_dir    = "$cmakelocal/lib";

    unshift @INC, $lib_dir;
}

use JSON::PP;
use File::Slurp qw(read_file);
use CMakeLocal::Bootstrap qw($PROJECT_ROOT $RULES_DIR);

# ------------------------------------------------------------
# Resolve paths (NEVER rely on cwd)
# ------------------------------------------------------------

# ------------------------------------------------------------
# Imports
# ------------------------------------------------------------

use CMakeLocal::Rules qw(
    extract_fields
);

use CMakeLocal::Resolve qw(
    resolve_all
);

use CMakeLocal::Contract qw(
    validate_contract
);

$| = 1;

# ------------------------------------------------------------
# Files
# ------------------------------------------------------------

my $RULES_FILE = "$RULES_DIR/cmake-rules.json";

# ------------------------------------------------------------
# Load rules
# ------------------------------------------------------------

my $rules = decode_json(
    scalar read_file($RULES_FILE, binmode => ":raw")
);

my ($fields_ref, $preset_fields_ref) = extract_fields($rules);
my %fields        = %{$fields_ref};
my %preset_fields = %{$preset_fields_ref};

# ------------------------------------------------------------
# CI shortcut (path-safe)
# ------------------------------------------------------------

if (($ENV{USE_CI_CONFIGURE} // "") eq "1") {
    system("bash", "$PROJECT_ROOT/ci/run/cmake-configure.sh") == 0
        or die "CI configure failed\n";
    exit 0;
}

# ------------------------------------------------------------
# Resolve + validate
# ------------------------------------------------------------

my %initial  = %ENV;
my %resolved = resolve_all(\%fields, \%initial);

validate_contract($rules, \%resolved);

# ------------------------------------------------------------
# Preset-derived values
# ------------------------------------------------------------

my %preset;

for my $id (keys %preset_fields) {
    if (exists $ENV{$id}) {
        $preset{$id} = $ENV{$id};
    }
    elsif (exists $preset_fields{$id}{default}) {
        $preset{$id} = $preset_fields{$id}{default};
    }
}

# ------------------------------------------------------------
# CMake paths
# ------------------------------------------------------------

my $src_dir = $PROJECT_ROOT;

my $build_dir =
       $preset{binaryDir}
    // $ENV{BUILD_DIR}
    // "$PROJECT_ROOT/build-cmake";

my $generator =
       $preset{generator}
    // $ENV{CMAKE_GENERATOR}
    // "Unix Makefiles";

# ------------------------------------------------------------
# Build CMake command
# ------------------------------------------------------------

my @cmake = (
    "cmake",
    "-S", $src_dir,
    "-B", $build_dir,
    "-G", $generator,
);

for my $id (sort keys %resolved) {
    my $f = $fields{$id} or next;
    my $k = $f->{cmake_key} or next;
    next unless defined $resolved{$id};
    push @cmake, "-D$k=$resolved{$id}";
}

# ------------------------------------------------------------
# Configure
# ------------------------------------------------------------

system(@cmake) == 0
    or die "cmake configure failed\n";

print "\nConfigure complete.\n";

# ------------------------------------------------------------
# Build
# ------------------------------------------------------------

system("cmake", "--build", $build_dir) == 0
    or die "cmake build failed\n";

print "Build complete.\n";
