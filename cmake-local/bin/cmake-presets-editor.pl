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

use CMakeLocal::Bootstrap qw($BIN_DIR $CMAKELOCAL $PROJECT_ROOT $RULES_DIR);

# ------------------------------------------------------------
# Resolve paths (NEVER rely on cwd)
# ------------------------------------------------------------

# ------------------------------------------------------------
# Imports
# ------------------------------------------------------------

use Storable qw(dclone);
use File::Temp qw(tempdir);

use CMakeLocal::IO qw(
    load_json_file
    save_json_file
);

use CMakeLocal::Util qw(
    normalize_onoff
    validate_enum
);

use CMakeLocal::Resolve qw(
    eval_default_if_preview
);

use CMakeLocal::Presets qw(
    find_preset
    clear_preset_cache
);

use CMakeLocal::Config qw(
    read_simple_conf
);

use CMakeLocal::MenuUX qw(
    with_menu_context
    menu_context_title
    prompt_menu_choice
    prompt_menu_input
    render_context_menu
    confirm_prompt
    set_menu_status
);

use File::Slurp qw(read_file write_file);

# ------------------------------------------------------------
# Files
# ------------------------------------------------------------

my $SYSTEM_PRESETS_FILE = "$PROJECT_ROOT/CMakePresets.json";
my $USER_PRESETS_FILE   = "$PROJECT_ROOT/CMakePresets.user.json";
my $RULES_FILE   = "$RULES_DIR/cmake-rules.json";

my %PRESET_ROOT_KEYS = map { $_ => 1 } qw(
    name
    displayName
    generator
    binaryDir
);

# ============================================================
# Load JSON files
# ============================================================

my $rules = load_json_file($RULES_FILE)
    or die "Missing $RULES_FILE\n";

my $system_data = load_json_file($SYSTEM_PRESETS_FILE) || {
    version => 6,
    cmakeMinimumRequired => { major => 3, minor => 16, patch => 0 },
    configurePresets => [],
    buildPresets     => [],
};

my $user_raw;
if (-f $USER_PRESETS_FILE) {
    $user_raw = (-s $USER_PRESETS_FILE) ? load_json_file($USER_PRESETS_FILE) : undef;
}
else {
    $user_raw = undef;
}

my $data = $user_raw || {
    version => 6,
    cmakeMinimumRequired => { major => 3, minor => 16, patch => 0 },
    configurePresets => [],
    buildPresets     => [],
};

my $system_presets = $system_data->{configurePresets} // [];
my $user_presets = $data->{configurePresets};
my $CONFIG_FILE = "$PROJECT_ROOT/cmake-local.conf";
my %local_config = (-f $CONFIG_FILE) ? read_simple_conf($CONFIG_FILE) : ();
my $allow_system_presets_edit = lc($local_config{allow_system_presets_edit} // "false") eq "true";
my $system_dirty = 0;
my $active_source = $local_config{default_preset_source} // 'system';
if (!$allow_system_presets_edit) {
    if (@{ $user_presets }) {
        $active_source = 'user';
    }
    else {
        $active_source = 'user'; # ensure we never treat system as active when read-only
    }
}

# helper to detect duplicates that exist in memory
sub preset_exists_in_memory {
    my ($source, $name) = @_;
    return 0 unless defined $name && $name ne '';
    my $list = $source eq 'system' ? $system_presets : $data->{configurePresets};
    for my $preset (@$list) {
        next unless defined $preset->{name};
        return 1 if $preset->{name} eq $name;
    }
    return 0;
}

sub rebuild_build_presets {
    $data->{buildPresets} = [
        map { { name => $_->{name}, configurePreset => $_->{name} } }
        @{ $data->{configurePresets} }
    ];
}

# ============================================================
# Show CMake defaults
# ============================================================

sub show_defaults {
    my $tmp = tempdir(CLEANUP => 1);

    system("cmake", "-S", $PROJECT_ROOT, "-B", $tmp) == 0
        or die "CMake configure failed\n";

    open my $fh, "<", "$tmp/CMakeCache.txt"
        or die "Cannot read CMakeCache.txt\n";

    print "\n=== CMake default values (effective) ===\n\n";

    while (<$fh>) {
        next unless /^[A-Z0-9_]+:/;
        next unless /^(XYMON_|ENABLE_|USE_|INSTALL|RRD|PCRE|SSL|LDAP|CARES|MAILPROGRAM)/;
        chomp;
        print "$_\n";
    }

    close $fh;
    print "\n";
}

# ============================================================
# View preset
# ============================================================

sub view_preset {
    my ($source, $idx) = @_;
    my $p = ($source eq 'system'
            ? ($system_presets->[$idx] // die "Invalid system index\n")
            : ($data->{configurePresets}->[$idx] // die "Invalid user index\n"));

    print "\n=== VIEW PRESET: $p->{name} ===\n";

    for my $section (@{ $rules->{sections} }) {
        my $section_title = $section->{title} // "(section)";
        print "\n[$section_title]\n";
        for my $f (@{ $section->{fields} }) {
            my $k = $f->{cmake_key};
            my $v =
                $p->{$k}
                // $p->{cacheVariables}{$k}
                // "(undefined)";
            my $field_label = $f->{id} // $k // "(field)";
            print "  $field_label: $v\n";
        }
    }
    print "\n";
}

# ============================================================
# Edit preset
# ============================================================

sub _preset_field_type {
    my ($type) = @_;
    return 'boolean' if $type && $type eq 'bool_onoff';
    return 'enum'    if $type && $type eq 'enum';
    return 'path'    if $type && $type =~ /path/;
    return 'string';
}

sub _preset_value_target {
    my ($key, $preset, $cv) = @_;
    return $PRESET_ROOT_KEYS{$key} ? $preset : $cv;
}

sub _preset_current_value {
    my ($entry, $preset, $cv) = @_;
    my $key = $entry->{key};
    my $target = _preset_value_target($key, $preset, $cv);
    my $value = defined $target->{$key} && $target->{$key} ne ''
        ? $target->{$key}
        : undef;
    if (!defined $value || $value eq '') {
        $value = $entry->{default} if defined $entry->{default};
    }
    return defined $value ? $value : '(unset)';
}

sub _preset_entry_line {
    my ($entry, $preset, $cv) = @_;
    return "$entry->{label} = " . _preset_current_value($entry, $preset, $cv);
}

sub _preset_choose_enum_value {
    my ($entry, $preset, $cv) = @_;
    my @choices = @{ $entry->{choices} // [] };
    return unless @choices;
    return with_menu_context(['Select value', $entry->{label}], sub {
        while (1) {
            render_context_menu(undef, \@choices, { extra => ['  b) Back'], spacing => 1 });
            my $choice = prompt_menu_choice(
                prompt => "Select value (or 'b' to go back): ",
                back => 1,
                clear => 1
            );
            return if $choice->{type} eq 'quit' || $choice->{type} eq 'back';
            next if $choice->{type} eq 'invalid';
            if ($choice->{type} eq 'index') {
                my $idx = $choice->{value} - 1;
                return $choices[$idx] if defined $choices[$idx];
                print "Invalid choice\n";
                next;
            }
        }
    });
}

sub _preset_apply_entry_action {
    my ($entry, $preset, $cv) = @_;
    my $type = $entry->{type};
    my $key  = $entry->{key};
    my $target = _preset_value_target($key, $preset, $cv);

    if ($type eq 'boolean') {
        my $current = normalize_onoff($target->{$key} // 'OFF');
        $target->{$key} = $current eq 'ON' ? 'OFF' : 'ON';
        print "$entry->{label} -> $target->{$key}\n";
    }
    elsif ($type eq 'enum') {
        my $new_value = _preset_choose_enum_value($entry, $preset, $cv);
        if (defined $new_value) {
            $target->{$key} = validate_enum($new_value, $entry->{choices});
            print "$entry->{label} -> $target->{$key}\n";
        }
    }
    else {
        my $prompt = $entry->{prompt} // $entry->{label};
        my $current = $target->{$key} // '';
        my $new_prompt = $current ne '' ? "$prompt [$current]: " : "$prompt: ";
        my $new = prompt_menu_input($new_prompt, clear => 1, default => $current);
        return unless defined $new;
        if ($entry->{optional} && $new eq '') {
            print "$entry->{label} left unchanged\n";
            return;
        }
        $target->{$key} = $new;
        print "$entry->{label} updated\n";
    }
}

sub _preset_section_entries {
    my ($section, $preset, $cv) = @_;
    my @entries;
    for my $f (@{ $section->{fields} }) {
        next if $f->{type} && $f->{type} eq 'computed';
        if (exists $f->{visible_if}) {
            my $visible = 1;
            for my $k (keys %{ $f->{visible_if} }) {
                my $v = $f->{visible_if}{$k};
                $visible = 0 unless ($cv->{$k} // "") eq $v;
            }
            next unless $visible;
        }
        my $key = $f->{cmake_key};
        my $type = _preset_field_type($f->{type});
        my $default = $f->{default};
        if (exists $f->{default_if}) {
            my $computed = eval_default_if_preview($f->{default_if}, $preset, $cv);
            $default = $computed if defined $computed;
        }
        push @entries, {
            label    => $f->{id} // $key,
            key      => $key,
            type     => $type,
            choices  => $f->{enum} ? [ @{ $f->{enum} } ] : undef,
            prompt   => $f->{caption} // $f->{id} // $key,
            default  => $default,
            optional => $f->{type} && $f->{type} eq 'path_optional',
        };
    }
    return \@entries;
}

sub _section_menu_entry {
    my ($section, $preset, $cv) = @_;
    my $entries = _preset_section_entries($section, $preset, $cv);
    return unless @$entries;
    return {
        title => $section->{title} // '(section)',
        entries => $entries,
    };
}

sub _edit_section_entries {
    my ($section_info, $preset, $cv) = @_;
    my $entries = $section_info->{entries};
    return with_menu_context($section_info->{title}, sub {
        while (1) {
            my @lines = map { _preset_entry_line($_, $preset, $cv) } @$entries;
            render_context_menu(undef, \@lines, {
                extra => ['  b) Back'],
                spacing => 1,
            });
            my $choice = prompt_menu_choice(
                prompt => "Select an entry or 'b' to return: ",
                back => 1,
                clear => 1
            );
            last if $choice->{type} eq 'back';
            last if $choice->{type} eq 'quit';
            next if $choice->{type} eq 'invalid';
            if ($choice->{type} eq 'index') {
                my $idx = $choice->{value} - 1;
                if ($idx >= 0 && $idx < @$entries) {
                    _preset_apply_entry_action($entries->[$idx], $preset, $cv);
                }
                else {
                    print "Invalid selection\n";
                }
            }
        }
    });
}

sub edit_preset {
    my ($source, $idx) = @_;
    my $preset = ($source eq 'system'
            ? ($system_presets->[$idx] // die "Invalid system index\n")
            : ($data->{configurePresets}->[$idx] // die "Invalid user index\n"));

    print "\n=== EDIT PRESET: $preset->{name} ===\n";
    my $cv = $preset->{cacheVariables} //= {};

    my @sections = map { _section_menu_entry($_, $preset, $cv) } @{ $rules->{sections} };
    @sections = grep { defined $_ } @sections;
    my @section_lines = map { $_->{title} } @sections;

    with_menu_context(['Edit preset', $preset->{name}], sub {
        while (1) {
            render_context_menu(undef, \@section_lines, {
                extra => ['  q) Quit section navigator'],
                spacing => 1,
            });
            my $choice = prompt_menu_choice(
                prompt => "Select a section (#) or 'q' to exit: ",
                back => 0,
                clear => 1
            );
            last if $choice->{type} eq 'quit';
            next if $choice->{type} eq 'invalid';
            if ($choice->{type} eq 'index') {
                my $section_idx = $choice->{value} - 1;
                if ($section_idx >= 0 && $section_idx < @sections) {
                    _edit_section_entries($sections[$section_idx], $preset, $cv);
                }
                else {
                    print "Invalid selection\n";
                }
            }
        }
    });

    $system_dirty = 1 if $source eq 'system';

    print "\nUpdated preset.\n\n";
}

# ============================================================
# Clone / Remove / Diff
# ============================================================

sub resolve_source_index {
    my ($token, $default_source) = @_;
    $default_source ||= $active_source // 'system';
    if ($token =~ /^([su])(\d+)$/i) {
        my $source = lc($1) eq "s" ? "system" : "user";
        return ($source, $2 - 1);
    }
    elsif ($token =~ /^(\d+)$/) {
        my $idx = $1 - 1;
        my $source = ($default_source eq 'user' && @{ $user_presets }) ? 'user' : 'system';
        if ($source eq 'user' && !defined $user_presets->[$idx]) {
            print "Invalid user index\n";
            return;
        }
        if ($source eq 'system' && !defined $system_presets->[$idx]) {
            print "Invalid system index\n";
            return;
        }
        return ($source, $idx);
    }
    die "Invalid index format; prefix with s (system) or u (user).\n";
}

sub resolve_clone_index {
    my ($token) = @_;
    return resolve_source_index($token, $active_source);
}

sub preset_file_for_source {
    my ($source) = @_;
    return $source eq 'system' ? $SYSTEM_PRESETS_FILE : $USER_PRESETS_FILE;
}

sub add_preset_to_source {
    my ($source, $clone) = @_;
    if ($source eq 'system') {
        unless ($allow_system_presets_edit) {
            print "Cannot modify system presets; enable allow_system_presets_edit in cmake-local.conf first.\n";
            return 0;
        }
        push @{ $system_presets }, $clone;
        $system_dirty = 1;
        return 1;
    }
    push @{ $data->{configurePresets} }, $clone;
    return 1;
}

sub clone_preset_from_source {
    my ($source, $idx, $newname) = @_;

    my $src;
    if ($source eq "system") {
        $src = $system_presets->[$idx];
        die "Invalid system index\n" unless $src;
    }
    elsif ($source eq "user") {
        $src = $user_presets->[$idx];
        die "Invalid user index\n" unless $src;
    }
    else {
        die "Unknown source '$source'\n";
    }

    my $dest_source = $active_source;
    my $dest_file   = preset_file_for_source($dest_source);
    die "Preset exists\n"
        if preset_exists_in_memory($dest_source, $newname);
    die "Preset exists\n"
        if find_preset($newname,
            ($dest_source eq 'system' ? (standard => $dest_file) : (user => $dest_file)));

    my $clone = dclone($src);
    $clone->{name}        = $newname;
    $clone->{displayName} = $clone->{displayName} || $newname;

    return unless add_preset_to_source($dest_source, $clone);
}

sub remove_preset {
    my ($idx) = @_;
    splice @{ $data->{configurePresets} }, $idx, 1;
}

sub get_preset_by_token {
    my ($token) = @_;
    my ($source, $idx) = resolve_source_index($token);
    return unless defined $source;
    my $preset = $source eq 'system'
        ? $system_presets->[$idx]
        : $user_presets->[$idx];
    unless ($preset) {
        print "Preset index not found; try another number.\n";
        return;
    }
    return $preset;
}

sub diff_presets {
    my ($token_a, $token_b) = @_;
    my $left_preset  = get_preset_by_token($token_a);
    my $right_preset = get_preset_by_token($token_b);
    return unless $left_preset && $right_preset;
    my $left  = JSON::PP->new->pretty->encode($left_preset);
    my $right = JSON::PP->new->pretty->encode($right_preset);
    print "\n=== PRESET DIFF ===\n";
    my @left_lines  = split /\n/, $left;
    my @right_lines = split /\n/, $right;
    my $max = @left_lines > @right_lines ? @left_lines : @right_lines;
    for my $idx (0 .. $max - 1) {
        my $l = $left_lines[$idx] // "";
        my $r = $right_lines[$idx] // "";
        next if $l eq $r && $l eq "";
        if ($l eq $r) {
            printf "   %s\n", $l;
        }
        else {
            printf "-  %s\n", $l if $l ne "";
            printf "+  %s\n", $r if $r ne "";
        }
    }
}

# ============================================================
# Display table
# ============================================================

sub fmt {
    my ($s, $n) = @_;
    $s //= "";
    return sprintf("%-*s", $n, $s);
}

sub truncate_text {
    my ($text, $width) = @_;
    $width //= 30;
    return "" unless defined $text;
    return $text if length($text) <= $width;
    return substr($text, 0, $width - 3) . "...";
}

sub show_table {
    print "=== CMake Preset Editor (Xymon) ===\n";
    my $system_status = $allow_system_presets_edit ? "(editable)" : "(read-only)";
    my $user_status;
    if (-s $USER_PRESETS_FILE) {
        $user_status = "(editable)";
    }
    elsif (-e $USER_PRESETS_FILE) {
        $user_status = "(empty)";
    }
    else {
        $user_status = "(not created yet)";
    }
    my $default_source = $local_config{default_preset_source} // 'system';
    my $default_name    = $local_config{default_preset}        // '(unset)';
    my $active_prefix = ($active_source eq 'system') ? "* " : "  ";
    my $user_prefix   = ($active_source eq 'user')   ? "* " : "  ";
    print "Sources\n";
    printf "%sSystem(s): %s %s\n", $active_prefix, $SYSTEM_PRESETS_FILE, $system_status;
    printf "%sUser(u):   %s %s\n", $user_prefix, $USER_PRESETS_FILE, $user_status;
    print "* current working source\n\n";
    print "Presets:\n";
    print "Idx   Name         Display Name                    Generator            Binary Dir\n";
    print "----- ------------ ------------------------------- -------------------- ---------------------------\n";

    my $idx_sys = 1;
    for my $p (@{ $system_presets }) {
        my $idx_label = sprintf("s%d", $idx_sys);
        my $marker = ($default_source eq 'system' && $p->{name} eq $default_name) ? "*" : " ";
        printf "%-6s %-12s %-30s %-20s %s\n",
            "$marker $idx_label",
            fmt($p->{name},12),
            fmt(truncate_text($p->{displayName} // "-", 30), 30),
            fmt($p->{generator} // "-",20),
            $p->{binaryDir} // "-";
        $idx_sys++;
    }

    my $idx_user = 1;
    for my $p (@{ $user_presets }) {
        my $idx_label = sprintf("u%d", $idx_user);
        my $marker = ($default_source eq 'user' && $p->{name} eq $default_name) ? "*" : " ";
        printf "%-6s %-12s %-30s %-20s %s\n",
            "$marker $idx_label",
            fmt($p->{name},12),
            fmt(truncate_text($p->{displayName} // "-", 30), 30),
            fmt($p->{generator} // "-",20),
            $p->{binaryDir} // "-";
        $idx_user++;
    }

    unless (@{ $user_presets }) {
        print "\nNo user presets\n";
    }
    print "\n";
    print "Menu-driven actions follow; use the numbered menu below to operate on presets.\n";
    print "Press q to quit any menu or b to return.\n";
}

sub format_preset_line {
    my ($source, $index, $preset, $default_source, $default_name) = @_;
    my $marker = ($default_source eq $source && defined $preset->{name} && $preset->{name} eq $default_name)
        ? "*" : " ";
    my $label = sprintf("%s%d", $source eq 'system' ? 's' : 'u', $index);
    my $name = $preset->{name} // '(unnamed)';
    my $display = $preset->{displayName} // '-';
    my $generator = $preset->{generator} // '-';
    my $binary = $preset->{binaryDir} // '-';
    return sprintf(
        "%s %-4s %s %s %s %s",
        $marker,
        $label,
        fmt($name, 12),
        fmt(truncate_text($display, 24), 24),
        fmt($generator, 18),
        $binary
    );
}

sub build_preset_entries {
    my (%opts) = @_;
    my $sources = $opts{sources} // { system => 1, user => 1 };
    my $default_source = $local_config{default_preset_source} // 'system';
    my $default_name = $local_config{default_preset} // '';
    my @lines;
    my @tokens;

    if ($sources->{system}) {
        my $idx = 1;
        for my $preset (@{ $system_presets }) {
            push @lines,
                format_preset_line('system', $idx, $preset, $default_source, $default_name);
            push @tokens, "s$idx";
            $idx++;
        }
    }
    if ($sources->{user}) {
        my $idx = 1;
        for my $preset (@{ $user_presets }) {
            push @lines,
                format_preset_line('user', $idx, $preset, $default_source, $default_name);
            push @tokens, "u$idx";
            $idx++;
        }
    }

    return (\@lines, \@tokens);
}

sub select_preset_token {
    my (%opts) = @_;
    my $title = $opts{title} // 'Select a preset';
    my ($lines, $tokens) = build_preset_entries(sources => $opts{sources});
    unless (@$lines) {
        print "No presets available\n";
        return;
    }
    return with_menu_context($title, sub {
        while (1) {
            my @extra = @{ $opts{extra} // [] };
            push @extra, '  b) Back';
            render_context_menu(undef, $lines, { extra => \@extra, spacing => 1 });
            my $choice = prompt_menu_choice(prompt => 'Choice [q]: ', back => 1, clear => 1);
            if ($choice->{type} eq 'index') {
                my $value = $choice->{value};
                if ($value >= 1 && $value <= @$lines) {
                    return $tokens->[$value - 1];
                }
                print "Invalid choice\n";
                next;
            }
            if ($choice->{type} eq 'invalid') {
                print "Invalid choice\n";
                next;
            }
            return;
        }
    });
} 

sub action_view_preset {
    my $token = select_preset_token(title => 'Select preset to view');
    return unless $token;
    my ($source, $idx) = resolve_source_index($token);
    return unless defined $source;
    view_preset($source, $idx);
    my $preset = ($source eq 'system' ? $system_presets->[$idx] : $user_presets->[$idx]);
    set_menu_status("Viewed preset $preset->{name} ($source)");
}

sub action_edit_preset {
    my $token = select_preset_token(title => 'Select preset to edit');
    return unless $token;
    my ($source, $idx) = resolve_source_index($token);
    return unless defined $source;
    if ($source eq 'system' && !$allow_system_presets_edit) {
        print "System presets are read-only; enable allow_system_presets_edit in cmake-local.conf to edit them.\n";
        return;
    }
    edit_preset($source, $idx);
    my $preset = ($source eq 'system' ? $system_presets->[$idx] : $user_presets->[$idx]);
    set_menu_status("Edited preset $preset->{name}");
}

sub action_clone_preset {
    my $token = select_preset_token(title => 'Select preset to clone');
    return unless $token;
    my ($source, $idx) = resolve_source_index($token);
    return unless defined $source;
    with_menu_context('Clone preset', sub {
        my $name = prompt_menu_input('New preset name: ', clear => 1);
        return unless defined $name && $name ne '';
        eval {
            clone_preset_from_source($source, $idx, $name);
            print "Preset cloned as ${active_source}::$name\n";
            my $preset_name = ($source eq 'system' ? $system_presets->[$idx]{name} : $user_presets->[$idx]{name}) // '(unknown)';
            set_menu_status("Cloned preset $preset_name to ${active_source}::$name");
            1;
        } or do {
            chomp(my $err = $@ || "unknown error");
            print "Clone failed: $err\n";
            set_menu_status("Clone failed: $err");
        };
    });
}

sub action_remove_user_preset {
    unless (@{ $user_presets }) {
        print "No user presets to remove\n";
        return;
    }
    my $token = select_preset_token(
        title   => 'Select user preset to remove',
        sources => { user => 1 },
    );
    return unless $token;
    my ($source, $idx) = resolve_source_index($token);
    return unless defined $source && $source eq 'user';
    my $name = $user_presets->[$idx]{name} // '(unknown)';
    return unless confirm_prompt("Remove preset '$name'?", 'n');
    remove_preset($idx);
    print "User preset removed\n";
    set_menu_status("Removed user preset $name");
}

sub action_diff_presets {
    my $left = select_preset_token(title => 'Select left preset for diff');
    return unless $left;
    my $right = select_preset_token(title => 'Select right preset for diff');
    return unless $right;
    my $left_name  = get_preset_by_token($left)->{name}  // $left;
    my $right_name = get_preset_by_token($right)->{name} // $right;
    diff_presets($left, $right);
    set_menu_status("Diffed presets $left_name vs $right_name");
}

sub action_new_user_preset {
    return with_menu_context('Create user preset', sub {
        my $name = prompt_menu_input('New preset name: ', clear => 1);
        return unless defined $name && $name ne '';
        if (preset_exists_in_memory('user', $name)) {
            print "Preset '$name' already exists\n";
            return;
        }
        if (find_preset($name, user => $USER_PRESETS_FILE)) {
            print "Preset '$name' already exists\n";
            return;
        }
        push @{ $data->{configurePresets} }, {
            name           => $name,
            displayName    => $name,
            generator      => "Unix Makefiles",
            binaryDir      => "build/$name",
            cacheVariables => {},
        };
        print "User preset '$name' created\n";
        set_menu_status("Created user preset $name");
    });
}

sub action_set_default_preset {
    my $token = select_preset_token(title => 'Select default preset');
    return unless $token;
    set_default_preset_from_token($token);
}

sub action_switch_active_source {
    my @entries = (
        "Use system presets as working source",
        "Use user presets as working source",
    );
    return with_menu_context('Active source', sub {
        render_context_menu(undef, \@entries, { extra => ['  b) Back'], spacing => 1 });
        my $choice = prompt_menu_choice(prompt => 'Choice [q]: ', back => 1, clear => 1);
        return unless $choice->{type} eq 'index';
        if ($choice->{value} == 1) {
            set_active_source('system');
        }
        elsif ($choice->{value} == 2) {
            set_active_source('user');
        }
        else {
            print "Invalid choice\n";
        }
    });
}

sub action_show_defaults {
    show_defaults();
}

sub action_write_and_exit {
    rebuild_build_presets();
    save_json_file($USER_PRESETS_FILE, $data);
    clear_preset_cache($USER_PRESETS_FILE);
    if ($allow_system_presets_edit && $system_dirty) {
        save_json_file($SYSTEM_PRESETS_FILE, $system_data);
        clear_preset_cache($SYSTEM_PRESETS_FILE);
    }
    exit 0;
}

sub update_config_default_preset {
    my ($source, $name) = @_;
    my $preset_line = "default_preset = $name\n";
    my $source_line = "default_preset_source = $source\n";
    my $found_preset = 0;
    my $found_source = 0;

    my @lines = read_file($CONFIG_FILE);
    for my $line (@lines) {
        if ($line =~ /^\s*default_preset\s*=/) {
            $line = $preset_line;
            $found_preset = 1;
        }
        elsif ($line =~ /^\s*default_preset_source\s*=/) {
            $line = $source_line;
            $found_source = 1;
        }
    }
    push @lines, $preset_line unless $found_preset;
    push @lines, $source_line unless $found_source;
    write_file($CONFIG_FILE, join("", @lines));
}

sub set_default_preset_from_token {
    my ($token) = @_;
    my ($source, $idx) = resolve_source_index($token);
    return unless defined $source;
    my $preset = $source eq "system" ? $system_presets->[$idx] : $user_presets->[$idx];
    unless ($preset) {
        print "Preset index not found; try another number.\n";
        return;
    }

    update_config_default_preset($source, $preset->{name});
    $local_config{default_preset_source} = $source;
    $local_config{default_preset}        = $preset->{name};

    print "Default preset set to $source::$preset->{name}\n";
}

sub set_active_source {
    my ($source) = @_;
    return unless defined $source;
    $source = lc($source);
    unless ($source =~ /^(system|user)$/) {
        print "Unknown source '$source'; use 'system' or 'user'.\n";
        return;
    }
    if ($source eq 'user' && !@{ $user_presets }) {
        print "No user presets yet; add one before using that source.\n";
        return;
    }
    if ($source eq 'system' && !$allow_system_presets_edit) {
        print "System presets are read-only; enable allow_system_presets_edit in cmake-local.conf to switch to them.\n";
        return;
    }
    $active_source = $source;
    print "Active source for numbered commands is now '$active_source'.\n";
}

# ============================================================
# MAIN LOOP
# ============================================================

with_menu_context(['Explore', 'Preset Editor'], sub {
    while (1) {
        show_table();
        my @entries = (
            "View preset",
            "Edit preset",
            "Clone preset",
            "Remove user preset",
            "Diff presets",
            "Create new user preset",
            "Set default preset",
            "Switch active source",
            "Show CMake defaults",
            "Write & exit",
        );
        render_context_menu(undef, \@entries, { extra => ['  b) Back'], spacing => 1 });
        my $choice = prompt_menu_choice(prompt => 'Choice [q]: ', back => 1, clear => 1);

        if ($choice->{type} eq 'quit') {
            exit 0;
        }
        if ($choice->{type} eq 'back') {
            exit 0;
        }
        if ($choice->{type} eq 'invalid') {
            next;
        }

        my $value = $choice->{value} // 0;
        if    ($value == 1) { action_view_preset(); }
        elsif ($value == 2) { action_edit_preset(); }
        elsif ($value == 3) { action_clone_preset(); }
        elsif ($value == 4) { action_remove_user_preset(); }
        elsif ($value == 5) { action_diff_presets(); }
        elsif ($value == 6) { action_new_user_preset(); }
        elsif ($value == 7) { action_set_default_preset(); }
        elsif ($value == 8) { action_switch_active_source(); }
        elsif ($value == 9) { action_show_defaults(); }
        elsif ($value == 10) { action_write_and_exit(); }
        else {
            print "Invalid choice\n";
        }
    }
});
