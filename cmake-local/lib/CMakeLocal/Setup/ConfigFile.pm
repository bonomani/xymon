package CMakeLocal::Setup::ConfigFile;

use strict;
use warnings;
use Exporter 'import';

use File::Slurp qw(read_file write_file);
use CMakeLocal::Bootstrap qw($BIN_DIR $PROJECT_ROOT);

our @EXPORT_OK = qw(
    ensure_local_config
    reset_local_config_template
    print_file_statuses
    file_status
    config_file_path
);

my $CONF_FILE    = "$PROJECT_ROOT/cmake-local.conf";

sub config_file_path {
    return $CONF_FILE;
}

sub _prompt_yes {
    my ($msg, $default) = @_;
    return 0 unless -t STDIN;
    print "$msg [$default]: ";
    chomp(my $ans = <STDIN>);
    $ans = $default if $ans eq "";
    return lc($ans) eq "y" || lc($ans) eq "yes";
}

sub ensure_local_config {
    unless (-f $CONF_FILE) {
        print "cmake-local.conf not found.\n";
        unless (_prompt_yes("Create cmake-local.conf now?", "y")) {
            warn "Skipping config creation; cmake-local.conf is required to edit settings.\n";
            return 0;
        }
        print "Creating cmake-local.conf (cmake-local-config-init.pl)\n";
        system($^X, "$BIN_DIR/cmake-local-config-init.pl") == 0
            or die "Failed to initialize cmake-local.conf\n";
    }
    return 1;
}

sub reset_local_config_template {
    print "\nThis will overwrite cmake-local.conf with the template.\n";
    return 0 unless _prompt_yes("Reset cmake-local.conf now?", "n");
    print "Resetting cmake-local.conf (cmake-local-config-init.pl --force)\n";
    my $ok = system($^X, "$BIN_DIR/cmake-local-config-init.pl", "--force") == 0;
    unless ($ok) {
        warn "Failed to reset cmake-local.conf\n";
        return 0;
    }
    return 1;
}

sub file_status {
    my ($label, $path) = @_;
    printf "  %-25s : %s\n", $label, (-f $path ? "present" : "missing");
}

sub print_file_statuses {
    print "\nFile status:\n";
    file_status("cmake-local.conf", $CONF_FILE);
    file_status("CMakePresets.user.json", "$PROJECT_ROOT/CMakePresets.user.json");
    file_status("CMakePresets.json (system)", "$PROJECT_ROOT/CMakePresets.json");
}

1;
