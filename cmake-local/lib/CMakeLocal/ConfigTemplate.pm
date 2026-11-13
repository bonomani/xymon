package CMakeLocal::ConfigTemplate;

use strict;
use warnings;
use Exporter 'import';

use CMakeLocal::Config qw(now_timestamp);

our @EXPORT_OK = qw(
    default_config_content
);

sub default_config_content {
    return <<"EOF";
# ----- preset / selection -----

default_preset = default
default_preset_source = system
auto_select_if_single = true
allow_fallback_to_editor = true

# ----- execution policy -----

default_mode = explore
clean_build_dir = true
confirm_before_install = true
parallel_build = auto
allow_non_tty = false

# ----- UX / menu -----

show_advanced_sections = false
hidden_sections = libraries
hidden_fields = RRDINCDIR,RRDLIBDIR,PCREINCDIR,PCRELIBDIR

# ----- safety -----

require_explicit_install = true
allow_system_presets_edit = false

# ----- metadata -----

last_used_preset = default
last_run_timestamp = @{[ now_timestamp() ]}
EOF
}

1;
