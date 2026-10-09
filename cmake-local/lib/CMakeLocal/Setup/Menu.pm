package CMakeLocal::Setup::Menu;

use strict;
use warnings;
use Exporter 'import';

use File::Slurp qw(read_file write_file);
use CMakeLocal::Bootstrap qw($BIN_DIR $PROJECT_ROOT);
use CMakeLocal::ConfigFile qw(config_bool config_value load_config);
use CMakeLocal::ConfigMenu qw(render_menu_line);
use CMakeLocal::MenuUX qw(
    with_menu_context
    menu_context_title
    prompt_menu_choice
    prompt_menu_input
    confirm_prompt
    set_menu_status
    render_context_menu
);
use CMakeLocal::Presets qw(collect_presets);
use CMakeLocal::Setup::ConfigFile qw(
    ensure_local_config
    reset_local_config_template
    print_file_statuses
);

our @EXPORT_OK = qw(
    print_variant_info
    print_preset_summary
    choose_default_preset
    explore_menu
);

my $CONF_FILE    = "$PROJECT_ROOT/cmake-local.conf";

my %PRESET_FILES = (
    standard => "$PROJECT_ROOT/CMakePresets.json",
    user     => "$PROJECT_ROOT/CMakePresets.user.json",
);

sub load_ordered_presets {
    collect_presets(%PRESET_FILES);
}

sub update_default_preset_in_conf {
    my ($preset, $source) = @_;

    my @lines = read_file($CONF_FILE);
    my $preset_line  = "default_preset = $preset\n";
    my $source_line  = "default_preset_source = $source\n";
    my $found_preset = 0;
    my $found_source = 0;

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

    write_file($CONF_FILE, join("", @lines));
    print "Updated cmake-local.conf default preset to $preset ($source)\n";
}

sub preset_key_parts {
    my ($key) = @_;
    my ($source, $name) = split(/::/, $key, 2);
    return ($source // "system", $name // $key);
}

sub print_variant_info {
    my ($variant, $localclient, $features_ref) = @_;
    my $mode_note = $variant eq "server"
        ? "server (server + client)"
        : "client-only ($localclient)";
    print "\n== Effective features ==\n";
    print "Mode: $mode_note\n\n";
    for my $k (sort keys %{$features_ref}) {
        printf "  %-20s : %s\n", $k, $features_ref->{$k};
    }
}

sub print_preset_summary {
    my ($config_ref) = @_;
    my $preset_name   = config_value($config_ref, 'default_preset', 'default');
    my $preset_source = config_value($config_ref, 'default_preset_source', 'system');
    print "\nUsing preset: $preset_name ($preset_source)\n";
}

sub choose_default_preset {
    my ($config_ref) = @_;
    my $catalog = load_ordered_presets();
    my @keys    = sort keys %{ $catalog->{merged_keys} };
    unless (@keys) {
        print "No presets available\n";
        return 0;
    }

    my @entries = map {
        my ($source, $name) = preset_key_parts($_);
        "$name ($source)";
    } @keys;

    return with_menu_context(['Explore', 'Config Editor', 'Default preset'], sub {
        while (1) {
            render_menu_line(menu_context_title(), \@entries, { back => 1 });
            my $choice = prompt_menu_input('Choice [q]: ', clear => 1);
            return 0 unless defined $choice;
            return 0 if $choice eq "" || lc($choice) eq "q";
            return 0 if lc($choice) eq "b";

            my $selected_key;
            if ($choice =~ /^\d+$/ && $choice >= 1 && $choice <= @keys) {
                $selected_key = $keys[$choice - 1];
            }
            elsif (grep { $_ eq $choice } @keys) {
                $selected_key = $choice;
            }

            if ($selected_key) {
                my ($source, $name) = preset_key_parts($selected_key);
                update_default_preset_in_conf($name, $source);
                set_menu_status("Default preset set to $source::$name");
                return 1;
            }

            print "Invalid choice\n";
        }
    });
}

sub explore_menu {
    my ($config_ref, $refresh_cb, $preset_summary_cb) = @_;
    my $preset_name   = config_value($config_ref, 'default_preset', 'default');
    my $preset_source = config_value($config_ref, 'default_preset_source', 'system');
    print "\nExplore mode (build/install only via --install). Current preset: $preset_name ($preset_source)\n";

    my $show_quick_help = sub {
        with_menu_context('Quick help', sub {
            print "\nQuick help:\n";
            print "  1) config editor: tune cmake-local.conf safely\n";
            print "  2) preset editor: clone/edit user presets\n";
            print "  3) file statuses: confirm required files/things exist\n";
            print "  4) switch default preset to something else\n";
            print "  5) reset cmake-local.conf to defaults\n";
            print "  q) exit explore menu\n";
        });
    };

    return with_menu_context('Explore', sub {
        while (1) {
            my $user_file_missing = !-s $PRESET_FILES{user};
            my @entries = (
                'Edit cmake-local.conf',
                'Open preset editor',
                'Show file statuses',
                'Switch default preset',
                'Reset cmake-local.conf to defaults',
                'Quick help',
            );
            render_context_menu('Explore', \@entries, {
                extra => ['  q) Quit menu'],
            });
            my $choice = prompt_menu_choice(prompt => 'Choice [q]: ', back => 0, clear => 1);
            if ($choice->{type} eq 'quit') {
                last;
            }
            elsif ($choice->{type} eq 'invalid') {
                print "Invalid choice\n";
                next;
            }
            elsif ($choice->{type} eq 'index') {
                my $value = $choice->{value};
                if ($value == 1) {
                    next unless ensure_local_config();
                    my $run = sub {
                        system($^X, "$BIN_DIR/cmake-local-config.pl") == 0
                            or warn "cmake-local-config.pl failed\n";
                    };
                    $run->();
                    set_menu_status("Edited cmake-local.conf");
                }
                elsif ($value == 2) {
                    if ($user_file_missing) {
                        print "CMakePresets.user.json is missing/empty; the preset editor will create it once you add a user preset.\n";
                        next unless confirm_prompt("Continue?", 'n');
                    }
                    system($^X, "$BIN_DIR/cmake-presets-editor.pl") == 0
                        or warn "cmake-presets-editor.pl failed\n";
                    set_menu_status("Opened preset editor");
                }
                elsif ($value == 3) {
                    print_file_statuses();
                    set_menu_status("Displayed file statuses");
                }
                elsif ($value == 4) {
                    next unless ensure_local_config();
                    if (choose_default_preset($config_ref)) {
                        $refresh_cb->() if $refresh_cb;
                        $preset_summary_cb->($config_ref) if $preset_summary_cb;
                    }
                }
                elsif ($value == 5) {
                    next unless ensure_local_config();
                    if (reset_local_config_template()) {
                        $refresh_cb->() if $refresh_cb;
                        $preset_summary_cb->($config_ref) if $preset_summary_cb;
                        set_menu_status("Reset cmake-local.conf to defaults");
                    }
                }
                elsif ($value == 6) {
                    $show_quick_help->();
                    set_menu_status("Displayed quick help");
                }
                else {
                    print "Invalid choice\n";
                }
            }
        }
    });
}

1;
