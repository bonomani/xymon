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

use CMakeLocal::Bootstrap qw($BIN_DIR $PROJECT_ROOT);

# ------------------------------------------------------------
# Resolve paths (NEVER rely on cwd)
# ------------------------------------------------------------

my $SYSTEM_PRESETS_FILE = "$PROJECT_ROOT/CMakePresets.json";
my $USER_PRESETS_FILE   = "$PROJECT_ROOT/CMakePresets.user.json";
my $conf_file           = "$PROJECT_ROOT/cmake-local.conf";

# ------------------------------------------------------------
# Imports
# ------------------------------------------------------------

use CMakeLocal::Config qw(
    read_simple_conf
    write_simple_conf
    prompt
    now_timestamp
);

use CMakeLocal::Presets qw(
    collect_presets
    list_preset_keys
);

use CMakeLocal::ConfigMenu qw(
    menu_title
    render_menu
    render_menu_with_footer
);

my @CONFIG_FIELDS = (
    { label => 'Default preset', key => 'default_preset', type => 'editor',
      value_cb => \&_default_preset_label, handler => \&_edit_default_preset },
    { label => 'Auto select if single preset', key => 'auto_select_if_single', type => 'boolean',
      choices => [qw(true false)] },
    { label => 'Allow fallback to editor', key => 'allow_fallback_to_editor', type => 'boolean',
      choices => [qw(true false)] },
    { label => 'Default mode', key => 'default_mode', type => 'enum', choices => [qw(explore install)] },
    { label => 'Clean build dir', key => 'clean_build_dir', type => 'boolean',
      choices => [qw(true false)] },
    { label => 'Confirm before install', key => 'confirm_before_install', type => 'boolean',
      choices => [qw(true false)] },
    { label => 'Parallel build', key => 'parallel_build', type => 'string' },
    { label => 'Allow non-TTY', key => 'allow_non_tty', type => 'boolean',
      choices => [qw(true false)] },
    { label => 'Show advanced sections', key => 'show_advanced_sections', type => 'boolean',
      choices => [qw(true false)] },
    { label => 'Hidden sections', key => 'hidden_sections', type => 'string' },
    { label => 'Hidden fields', key => 'hidden_fields', type => 'string' },
    { label => 'Require explicit install', key => 'require_explicit_install', type => 'boolean',
      choices => [qw(true false)] },
    { label => 'Edit system presets', key => 'allow_system_presets_edit', type => 'boolean',
      choices => [qw(true false)] },
);

sub _default_preset_label {
    my ($cfg_ref) = @_;
    my $src  = $cfg_ref->{default_preset_source} // 'system';
    my $name = $cfg_ref->{default_preset}        // '(unset)';
    return "${src}::$name";
}

sub _edit_default_preset {
    my ($cfg_ref, $preset_keys_ref, $user_exists) = @_;
    unless (@$preset_keys_ref) {
        print "No presets available; cannot change default preset.\n";
        return;
    }

    my @entries;
    for my $key (@$preset_keys_ref) {
        my ($source, $name) = key_parts($key);
        push @entries, "$name ($source)";
    }

    render_menu(menu_title('Explore', 'Config Editor', 'Default preset'), \@entries, { back => 1 });
    print "Select default preset (# or key, or 'b' to cancel) [current: "
        . _default_preset_label($cfg_ref) . "]: ";
    chomp(my $selection = <STDIN>);
    return if !defined $selection || $selection eq '';
    return if lc($selection) eq 'b';

    my $selected_key;
    if ($selection =~ /^\d+$/) {
        $selected_key = $preset_keys_ref->[$selection - 1];
    }
    elsif (grep { $_ eq $selection } @$preset_keys_ref) {
        $selected_key = $selection;
    }

    unless ($selected_key) {
        warn "Invalid selection; keeping default preset.\n";
        return;
    }

    my ($source, $name) = key_parts($selected_key);
    $cfg_ref->{default_preset_source} = normalize_source_choice($source, $user_exists);
    $cfg_ref->{default_preset}        = $name;
}

sub select_default_preset_by_source {
    my ($cfg_ref, $keys_ref, $source_label, $user_exists) = @_;
    unless (@{$keys_ref}) {
        print "No $source_label presets available.\n";
        return;
    }

    print "\nAvailable $source_label presets:\n";
    for my $idx (0 .. $#{ $keys_ref }) {
        my ($src, $name) = key_parts($keys_ref->[$idx]);
        printf "  %2d) %-30s (%s)\n", $idx + 1, $name, $src;
    }

    print "Select preset (# or key) [current: " . _default_preset_label($cfg_ref) . "]: ";
    chomp(my $selection = <STDIN>);
    return if !$selection;

    my $selected_key;
    if ($selection =~ /^\d+$/ && $selection >= 1 && $selection <= @{$keys_ref}) {
        $selected_key = $keys_ref->[$selection - 1];
    }
    elsif (grep { $_ eq $selection } @{$keys_ref}) {
        $selected_key = $selection;
    }

    unless ($selected_key) {
        warn "Invalid selection; keeping default preset.\n";
        return;
    }

    my ($source, $name) = key_parts($selected_key);
    $cfg_ref->{default_preset_source} = normalize_source_choice($source, $user_exists);
    $cfg_ref->{default_preset}        = $name;
    print "Default preset now: $source::$name\n";
}

sub _choose_field_value {
    my ($field, $cfg_ref) = @_;
    my @choices = @{ $field->{choices} // [] };
    return unless @choices;

    my $label   = $field->{prompt} // $field->{label};
    my $current = defined $cfg_ref->{$field->{key}} && $cfg_ref->{$field->{key}} ne ''
        ? $cfg_ref->{$field->{key}}
        : '(unset)';

    print "\n$label:\n";
    my $idx = 1;
    for my $choice (@choices) {
        print sprintf("  %2d) %s\n", $idx++, $choice);
    }
    print "Select value [current: $current]: ";
    chomp(my $selection = <STDIN>);
    return if !defined $selection || $selection eq "";

    if ($selection =~ /^\d+$/) {
        my $pos = $selection - 1;
        return $choices[$pos] if defined $choices[$pos];
    }
    for my $choice (@choices) {
        return $choice if lc($choice) eq lc($selection);
    }

    warn "Invalid choice; keeping '$current'.\n";
    return;
}

sub _field_display_for_menu {
    my ($cfg_ref, $field) = @_;
    my $value = defined $cfg_ref->{$field->{key}} && $cfg_ref->{$field->{key}} ne ''
        ? $cfg_ref->{$field->{key}}
        : '(unset)';
    if ($field->{value_cb}) {
        $value = $field->{value_cb}->($cfg_ref);
    }
    return "$field->{label} = $value";
}

sub _apply_field_action {
    my ($field, $cfg_ref, $preset_keys_ref, $user_exists) = @_;
    my $type = $field->{type} // 'string';
    if ($type eq 'boolean') {
        my $current = lc($cfg_ref->{$field->{key}} // '');
        my ($true, $false) = @{ $field->{choices} // [qw(true false)] };
        $true = 'true' unless defined $true;
        $false = 'false' unless defined $false;
        $cfg_ref->{$field->{key}} = $current eq lc($true) ? $false : $true;
        print "$field->{label} -> $cfg_ref->{$field->{key}}\n";
    }
    elsif ($type eq 'enum') {
        my $new_value = _choose_field_value($field, $cfg_ref);
        if (defined $new_value) {
            $cfg_ref->{$field->{key}} = $new_value;
            print "$field->{label} -> $new_value\n";
        }
    }
    elsif ($type eq 'path' || $type eq 'string') {
        my $prompt_label = $field->{prompt} // "New value";
        my $value = prompt($prompt_label, $cfg_ref->{$field->{key}} // '');
        if (defined $value && $value ne '') {
            $cfg_ref->{$field->{key}} = $value;
            print "$field->{label} updated\n";
        }
    }
    elsif ($type eq 'editor' && $field->{handler}) {
        $field->{handler}->($cfg_ref, $preset_keys_ref, $user_exists);
    }
}

sub edit_config_values {
    my ($cfg_ref, $preset_keys_ref, $system_keys_ref, $user_keys_ref, $user_exists) = @_;
    while (1) {
        my @entries = map { _field_display_for_menu($cfg_ref, $_) } @CONFIG_FIELDS;
        render_menu(menu_title('Explore', 'Config Editor'), \@entries, {
            back => 1,
            spacing => 1,
        });
        print "Choice [q]: ";
        chomp(my $choice = <STDIN>);
        $choice //= '';
        $choice =~ s/^\s+|\s+$//g;
        last if $choice eq '' || lc($choice) eq 'q' || lc($choice) eq 'b';
        if ($choice =~ /^\d+$/) {
            my $index = $choice - 1;
            if ($index >= 0 && $index < @CONFIG_FIELDS) {
                _apply_field_action($CONFIG_FIELDS[$index], $cfg_ref, $preset_keys_ref, $user_exists);
                next;
            }
        }
        print "Invalid choice. Try again.\n";
    }
}

sub print_preset_list {
    my ($keys) = @_;
    print "\n=== Available CMake presets ===\n\n";
    if (@$keys) {
        my $num = 1;
        for my $key (@$keys) {
            my ($source, $name) = key_parts($key);
            printf "  %2d) %-30s (%s)\n", $num++, $name, $source;
        }
    }
    else {
        print "  (no presets found)\n";
    }
}

sub print_preset_files {
    my ($user_exists) = @_;
    print "\nPreset files:\n";
    print "  System: $SYSTEM_PRESETS_FILE\n";
    if ($user_exists) {
        print "  User:   $USER_PRESETS_FILE (editable)\n";
    }
    else {
        print "  User:   $USER_PRESETS_FILE (not created yet)\n";
    }
}

sub run_config_editor {
    my ($cfg_ref, $preset_keys_ref, $user_exists) = @_;
    my %cfg = %{$cfg_ref};

    my $current_key;
    if ($cfg{default_preset_source} && $cfg{default_preset}) {
        $current_key = "$cfg{default_preset_source}::$cfg{default_preset}";
    }

    my $default_key;
    my $default_label = "";

    if ($current_key && grep { $_ eq $current_key } @$preset_keys_ref) {
        $default_key   = $current_key;
        $default_label = key_label($current_key);
    }
    elsif (@$preset_keys_ref) {
        $default_key   = $preset_keys_ref->[0];
        $default_label = key_label($default_key);
    }

    my @system_keys = grep { /^system::/ } @{$preset_keys_ref};
    my @user_keys   = grep { /^user::/ } @{$preset_keys_ref};
    print "=== cmake-local.conf editor ===\n";
    edit_config_values(\%cfg, $preset_keys_ref, \@system_keys, \@user_keys, $user_exists);

    $cfg{last_run_timestamp} = now_timestamp();
    %{$cfg_ref} = %cfg;

    print "\nWrite changes to cmake-local.conf? [y/N]: ";
    chomp(my $ans = <STDIN>);
    if (lc($ans) eq "y") {
        my $content = <<"EOF";
# ----- preset / selection -----

default_preset = $cfg{default_preset}
default_preset_source = $cfg{default_preset_source}
auto_select_if_single = $cfg{auto_select_if_single}
allow_fallback_to_editor = $cfg{allow_fallback_to_editor}

# ----- execution policy -----

default_mode = $cfg{default_mode}
clean_build_dir = $cfg{clean_build_dir}
confirm_before_install = $cfg{confirm_before_install}
parallel_build = $cfg{parallel_build}
allow_non_tty = $cfg{allow_non_tty}

# ----- UX / menu -----

show_advanced_sections = $cfg{show_advanced_sections}
hidden_sections = $cfg{hidden_sections}
hidden_fields = $cfg{hidden_fields}

# ----- safety -----

require_explicit_install = $cfg{require_explicit_install}
allow_system_presets_edit = $cfg{allow_system_presets_edit}

# ----- metadata -----

last_used_preset = $cfg{last_used_preset}
last_run_timestamp = $cfg{last_run_timestamp}
EOF

        write_simple_conf($conf_file, $content);
        print "cmake-local.conf updated\n";
    }
    else {
        print "No changes written\n";
    }
    exit 0;
}

sub config_menu {
    my ($cfg_ref, $preset_keys_ref, $system_keys_ref, $user_keys_ref, $user_exists) = @_;
    run_config_editor($cfg_ref, $preset_keys_ref, $user_exists);
}

sub key_parts {
    my ($key) = @_;
    return ("system", "unknown") unless defined $key;
    my ($source, $name) = split(/::/, $key, 2);
    $source //= "system";
    $name   //= $key;
    return ($source, $name);
}

sub key_label {
    my ($key) = @_;
    my ($source, $name) = key_parts($key);
    return "${source}::$name";
}

sub prompt_yes {
    my ($msg, $default) = @_;
    $default = defined $default ? lc($default) : "n";
    return 0 unless -t STDIN;
    print "$msg [" . ($default eq "y" ? "y" : "n") . "]: ";
    chomp(my $input = <STDIN>);
    $input = $default if $input eq "";
    return lc($input) eq "y" || lc($input) eq "yes";
}

sub normalize_source_choice {
    my ($value, $allow_user) = @_;
    $allow_user //= 1;
    return "user" if defined $value && lc($value) eq "user" && $allow_user;
    return "system";
}

# ------------------------------------------------------------
# Config file (stored at project root)
# ------------------------------------------------------------

-f $conf_file
    or die "cmake-local.conf not found (run cmake-local-config-init.pl first)\n";

# ------------------------------------------------------------
# Read config
# ------------------------------------------------------------

my %cfg = read_simple_conf($conf_file);

$cfg{default_preset_source} //= 'system';

# ------------------------------------------------------------
# Show available presets (standard + user)
# ------------------------------------------------------------

my @preset_keys = list_preset_keys(
    standard => $SYSTEM_PRESETS_FILE,
    user     => $USER_PRESETS_FILE,
);
my @system_keys = grep { /^system::/ } @preset_keys;
my @user_keys   = grep { /^user::/ } @preset_keys;
my $user_exists = -f $USER_PRESETS_FILE;

config_menu(\%cfg, \@preset_keys, \@system_keys, \@user_keys, $user_exists);
