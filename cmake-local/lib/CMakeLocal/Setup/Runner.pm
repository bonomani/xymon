package CMakeLocal::Setup::Runner;

use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(run);
use FindBin;
use Cwd qw(abs_path);
use File::Basename qw(dirname);
use File::Path qw(remove_tree make_path);
use JSON::PP;
use File::Slurp qw(read_file write_file);

use CMakeLocal::Util qw(
    normalize_onoff
    validate_enum
);
use CMakeLocal::Rules qw(
    extract_fields
    extract_cli_defs
);
use CMakeLocal::CLI qw(
    parse_cli
);
use CMakeLocal::Env qw(
    export_env
);
use CMakeLocal::ConfigFile qw(
    load_config
    config_bool
    config_value
);
use CMakeLocal::Presets qw(
    resolve_preset
    get_preset_binary_dir
);
use CMakeLocal::Setup::ConfigFile qw(
    print_file_statuses
);
use CMakeLocal::Setup::Menu qw(
    print_variant_info
    print_preset_summary
    explore_menu
);

my $BIN_DIR      = abs_path($FindBin::Bin);
my $CMAKELOCAL   = abs_path(dirname($BIN_DIR));
my $PROJECT_ROOT = abs_path(dirname($CMAKELOCAL));
my $RULES_DIR    = "$CMAKELOCAL/rules";
my $RULES_FILE   = "$RULES_DIR/cmake-rules.json";
my $CONF_FILE    = "$PROJECT_ROOT/cmake-local.conf";

sub load_rules {
    decode_json(scalar read_file($RULES_FILE, binmode => ":raw"));
}

sub load_config_data {
    load_config($CONF_FILE);
}

sub select_preset_name {
    my ($catalog, $default_name, $auto_select) = @_;
    my $merged = $catalog->{merged} // {};

    if ($default_name && exists $merged->{$default_name}) {
        return ($default_name, $merged->{$default_name}{source});
    }

    if ($auto_select) {
        my @user = map { $_->{name} } @{ $catalog->{user} // [] };
        if (@user == 1) {
            return ($user[0], $catalog->{merged}{$user[0]}{source});
        }

        my @merged_names = keys %$merged;
        if (@merged_names == 1) {
            return ($merged_names[0], $merged->{$merged_names[0]}{source});
        }
    }

    return;
}

sub system_default_from_catalog {
    my ($catalog) = @_;
    for my $p (@{ $catalog->{standard} // [] }) {
        next unless $p && $p->{name};
        return ($p->{name}, 'system');
    }
    my $merged = $catalog->{merged} // {};
    for my $name (keys %$merged) {
        return ($name, $merged->{$name}{source});
    }
    return;
}

sub normalize_source_label {
    my ($value) = @_;
    return "user" if defined $value && $value eq "user";
    return "system";
}

sub run {
    my (@argv) = @_;

    my $rules = load_rules();

    my ($fields_ref) = extract_fields($rules);
    my %fields       = %{$fields_ref};
    my %cli_defs     = extract_cli_defs($rules);

    my ($cli_values_ref, $flags_ref) = parse_cli(\@argv, \%cli_defs);
    my %cli_values = %{$cli_values_ref};
    my %flags      = %{$flags_ref};

    if ($flags{help}) {
        print_usage(%cli_defs);
        return;
    }

my $config_ref = load_config_data();
my %user_conf = $config_ref ? %{$config_ref} : ();

    my $default_mode           = lc(config_value(\%user_conf, 'default_mode', 'explore'));
    $default_mode              = "explore" unless $default_mode eq "install";
    my $require_explicit_install = config_bool(\%user_conf, 'require_explicit_install', 1);
    my $auto_install           = ($default_mode eq "install" && !$require_explicit_install) ? 1 : 0;
    my $do_install             = $flags{install} ? 1 : $auto_install;

    my $variant_f              = $fields{VARIANT};
    my $variant                = $cli_values{VARIANT} // $variant_f->{default};
    $variant                   = validate_enum($variant, $variant_f->{enum});

    my $localclient            = "";
    if ($variant eq "client") {
        my $lc = $fields{LOCALCLIENT};
        $localclient = $cli_values{LOCALCLIENT} // $lc->{default};
        $localclient = validate_enum($localclient, $lc->{enum});
    }

    my %features;
    for my $id (grep { /^ENABLE_/ } keys %fields) {
        my $f = $fields{$id};
        next unless $f->{default_by_variant};
        $features{$id} =
            $cli_values{$id}
            // normalize_onoff($f->{default_by_variant}{$variant});
    }

    if (exists $fields{USE_GNUINSTALLDIRS}) {
        my $def = $fields{USE_GNUINSTALLDIRS}{default} // "OFF";
        $features{USE_GNUINSTALLDIRS} =
            normalize_onoff($cli_values{USE_GNUINSTALLDIRS} // $def);
    }

    print "\n== Build variant ==\n";
    print_variant_info($variant, $localclient, \%features);
    print_preset_summary(\%user_conf);

    my $preset_name = config_value($config_ref, 'default_preset', 'default');
    my $preset_source = normalize_source_label(
        config_value($config_ref, 'default_preset_source', 'system')
    );
    my $preset_key = "${preset_source}::${preset_name}";
    my %preset_opts = (
        standard   => "$PROJECT_ROOT/CMakePresets.json",
        user       => "$PROJECT_ROOT/CMakePresets.user.json",
        source_dir => $PROJECT_ROOT,
    );
    my $resolved_preset = resolve_preset($preset_key, %preset_opts);
    my $preset_binary_dir = get_preset_binary_dir(
        $preset_key,
        %preset_opts,
        resolved_preset => $resolved_preset,
    );
    my $build_dir = $preset_binary_dir || "$PROJECT_ROOT/build-cmake";

    my $preset_generator = $resolved_preset
        ? $resolved_preset->{preset}{generator}
        : undef;

    my %env_vars = (
        ROOT_DIR  => $PROJECT_ROOT,
        BUILD_DIR => $build_dir,
        VARIANT   => $variant,
        (defined $preset_generator ? (generator => $preset_generator) : ()),
        ($variant eq "client" ? (LOCALCLIENT => $localclient) : ()),
        CMAKE_INSTALL_PREFIX =>
            $cli_values{CMAKE_INSTALL_PREFIX}
            // $fields{CMAKE_INSTALL_PREFIX}{default},
        XYMONTOPDIR =>
            $cli_values{XYMONTOPDIR}
            // $fields{XYMONTOPDIR}{default},
        %features,
    );

    export_env(%env_vars);

    if ($do_install) {
        run_install_flow(\%env_vars, \%user_conf, \@argv, $flags_ref);
    }
    else {
        explore_flow(\%env_vars, \%user_conf);
    }
}

sub print_usage {
    my (%cli_defs) = @_;
    print "Usage: cmake-local-setup.pl [options]\n\n";
    print "Options (from rules.json):\n\n";
    for my $opt (sort keys %cli_defs) {
        my $f = $cli_defs{$opt};
        print "  $opt";
        print " <value>" unless ($f->{type} // "") eq "bool_onoff";
        print " [" . join("|", @{ $f->{enum} }) . "]" if $f->{enum};
        print "\n";
    }
    print "\n  --install    build and install\n";
}

sub run_install_flow {
    my ($env_ref, $config_ref, $argv_ref, $flags_ref) = @_;
    my $build_dir = $env_ref->{BUILD_DIR};

    print "\nCleaning build directory: $build_dir\n";
    remove_tree($build_dir);
    make_path($build_dir);

    system($^X, "$BIN_DIR/cmake-local-build.pl") == 0
        or die "Build failed\n";

    system($^X, "$BIN_DIR/cmake-local-install.pl") == 0
        or die "Install failed\n";
}

sub refresh_user_config {
    my ($config_ref) = @_;
    my $new_ref = load_config_data();
    %{$config_ref} = $new_ref ? %{$new_ref} : ();
}

sub explore_flow {
    my ($env_ref, $config_ref) = @_;

    print "\n[explore] No build / no install performed\n";
    print "[explore] Re-run with --install to apply\n";
    print_file_statuses();

    explore_menu(
        $config_ref,
        sub { refresh_user_config($config_ref); },
        \&print_preset_summary
    );
}

1;
