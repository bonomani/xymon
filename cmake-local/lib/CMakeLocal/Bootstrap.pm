package CMakeLocal::Bootstrap;

use strict;
use warnings;
use Exporter 'import';

use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(dirname);

our @EXPORT_OK = qw(
    $BIN_DIR
    $CMAKELOCAL
    $PROJECT_ROOT
    $LIB_DIR
    $RULES_DIR
);

our ($BIN_DIR, $CMAKELOCAL, $PROJECT_ROOT, $LIB_DIR, $RULES_DIR);

BEGIN {
    $BIN_DIR    = abs_path($FindBin::Bin);
    $CMAKELOCAL = abs_path(dirname($BIN_DIR));
    $PROJECT_ROOT = abs_path(dirname($CMAKELOCAL));
    $LIB_DIR    = "$CMAKELOCAL/lib";
    $RULES_DIR  = "$CMAKELOCAL/rules";
}

1;
