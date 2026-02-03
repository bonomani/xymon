#!/usr/bin/env perl
use strict;
use warnings;

use FindBin;
use Cwd qw(abs_path);

use lib "$FindBin::Bin/../lib";
use CMakeLocal::Setup::Runner qw(run);

run(@ARGV);
