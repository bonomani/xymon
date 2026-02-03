package CMakeLocal::Presets;

use strict;
use warnings;
use Exporter 'import';

use CMakeLocal::IO qw(load_json_file);

our @EXPORT_OK = qw(
    load_presets_from_file
    collect_presets
    find_preset
    list_preset_names
    list_preset_keys
    resolve_preset
    get_preset_binary_dir
    clear_preset_cache
);

my %FILE_CACHE;

sub _file_mtime {
    my ($file) = @_;
    return undef unless defined $file;
    my @st = stat($file);
    return undef unless @st;
    return $st[9];
}

sub clear_preset_cache {
    my ($file) = @_;
    delete $FILE_CACHE{$file} if defined $file;
}

# ------------------------------------------------------------
# Low-level loader
# ------------------------------------------------------------

sub load_presets_from_file {
    my ($file) = @_;

    return ()
        unless defined $file && -f $file;

    return () unless -s $file;

    my $mtime = _file_mtime($file);
    my $entry = $FILE_CACHE{$file};
    if ($entry && defined $entry->{mtime} && defined $mtime && $entry->{mtime} == $mtime) {
        return @{ $entry->{presets} };
    }

    my $json = load_json_file($file)
        or return ();

    my @presets = @{ $json->{configurePresets} // [] };
    $FILE_CACHE{$file} = {
        mtime => $mtime,
        presets => \@presets,
    };

    return @presets;
}

# ------------------------------------------------------------
# Collect standard + user presets
# ------------------------------------------------------------

sub collect_presets {
    my (%opts) = @_;

    my $std_file  = $opts{standard};
    my $user_file = $opts{user};

    my @standard = load_presets_from_file($std_file);
    my @user     = load_presets_from_file($user_file);

    my %merged_by_name;
    my %merged_by_key;

    for my $p (@standard) {
        my $name = $p->{name} // next;
        my $key  = "system::$name";
        $merged_by_key{$key} = {
            preset => $p,
            source => 'system',
            name   => $name,
        };
        $merged_by_name{$name} //= {
            preset => $p,
            source => 'system',
        };
    }

    for my $p (@user) {
        my $name = $p->{name} // next;
        my $key  = "user::$name";
        $merged_by_key{$key} = {
            preset => $p,
            source => 'user',
            name   => $name,
        };
        $merged_by_name{$name} = {
            preset => $p,
            source => 'user',
        };
    }

    return {
        standard => \@standard,
        user     => \@user,
        merged   => \%merged_by_name,
        merged_keys => \%merged_by_key,
    };
}

# ------------------------------------------------------------
# Find a preset by name
# ------------------------------------------------------------

sub find_preset {
    my ($name_or_key, %opts) = @_;
    return undef unless defined $name_or_key;

    my $data = collect_presets(%opts);
    if ($name_or_key =~ /^(system|user)::/) {
        return $data->{merged_keys}{$name_or_key}{preset};
    }
    return $data->{merged}{$name_or_key}{preset};
}

# ------------------------------------------------------------
# List preset names
# ------------------------------------------------------------

sub list_preset_names {
    my (%opts) = @_;

    my $data = collect_presets(%opts);
    return sort keys %{ $data->{merged} };
}

sub list_preset_keys {
    my (%opts) = @_;

    my $data = collect_presets(%opts);
    return sort keys %{ $data->{merged_keys} };
}

# ------------------------------------------------------------
# Resolve a preset (future-proof)
# ------------------------------------------------------------

sub resolve_preset {
    my ($name_or_key, %opts) = @_;

    my $data = collect_presets(%opts);
    my $entry;
    if ($name_or_key =~ /^(system|user)::/) {
        $entry = $data->{merged_keys}{$name_or_key};
    }
    else {
        $entry = $data->{merged}{$name_or_key};
    }
    return undef unless $entry;

    return {
        name   => $entry->{name} // $name_or_key,
        source => $entry->{source},
        preset => $entry->{preset},
    };
}

# ------------------------------------------------------------
# Helper: get preset binaryDir (install / CI usage)
# ------------------------------------------------------------

sub get_preset_binary_dir {
    my ($name, %opts) = @_;
    return undef unless defined $name;

    my $resolved = resolve_preset($name, %opts)
        or return undef;

    my $preset = $resolved->{preset};
    my $dir    = $preset->{binaryDir}
        or return undef;

    if (defined $opts{source_dir}) {
        $dir =~ s/\$\{sourceDir\}/$opts{source_dir}/g;
    }

    return $dir;
}

1;
