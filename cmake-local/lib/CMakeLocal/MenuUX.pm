package CMakeLocal::MenuUX;

use strict;
use warnings;
use Exporter 'import';

use CMakeLocal::ConfigMenu qw(menu_title render_menu render_menu_with_footer);

our @EXPORT_OK = qw(
    with_menu_context
    menu_context_title
    prompt_menu_input
    prompt_menu_choice
    render_context_menu
    set_menu_status
    clear_menu_status
    confirm_prompt
    clear_prompt_line
);

my @CONTEXT_STACK;

sub with_menu_context {
    my ($label, $code) = @_;
    die "with_menu_context requires a code reference\n" unless defined $code && ref($code) eq 'CODE';

    my @labels;
    if (defined $label) {
        @labels = ref($label) eq 'ARRAY' ? @$label : ($label);
        @labels = grep { defined && $_ ne '' } @labels;
    }

    push @CONTEXT_STACK, @labels;
    my @result = eval { $code->() };
    my $error = $@;
    pop @CONTEXT_STACK for 1 .. scalar(@labels);
    die $error if $error;
    return wantarray ? @result : $result[0];
}

sub menu_context_title {
    my @extra = @_;
    my @parts = (@CONTEXT_STACK, grep { defined && $_ ne '' } @extra);
    return menu_title(@parts);
}

sub clear_prompt_line {
    return unless -t STDOUT;
    print "\r\x1b[2K";
}

sub prompt_menu_input {
    my ($prompt, %opts) = @_;
    $prompt //= '';
    print $prompt;
    my $input = <STDIN>;
    unless (defined $input) {
        clear_prompt_line() if $opts{clear};
        return undef;
    }
    chomp $input;
    $input =~ s/^\s+|\s+$//g;
    clear_prompt_line() if $opts{clear};
    if ($input eq '' && exists $opts{default}) {
        return $opts{default};
    }
    return $input;
}

sub prompt_menu_choice {
    my (%opts) = @_;
    my $prompt = $opts{prompt} // 'Choice [q]: ';
    my $allow_back = exists $opts{back} ? $opts{back} : 1;
    my $clear = exists $opts{clear} ? $opts{clear} : 0;

    while (1) {
        my $input = prompt_menu_input($prompt, clear => $clear);
        unless (defined $input) {
            return { type => 'quit' };
        }
        return { type => 'quit' } if $input eq '' || lc($input) eq 'q';
        if ($allow_back && lc($input) eq 'b') {
            return { type => 'back' };
        }
        if ($input =~ /^\d+$/) {
            return { type => 'index', value => int($input) };
        }
        return { type => 'invalid' };
    }
}

my $MENU_STATUS = '';

sub set_menu_status {
    my ($msg) = @_;
    $MENU_STATUS = defined $msg ? $msg : '';
}

sub clear_menu_status {
    $MENU_STATUS = '';
}

sub _menu_status_footer {
    return [] unless $MENU_STATUS && $MENU_STATUS ne '';
    return ["Last action: $MENU_STATUS"];
}

sub render_context_menu {
    my ($title, $entries, $opts) = @_;
    $opts //= {};
    my @extra = @{ $opts->{extra} // [] };
    my $menu_opts = {
        extra   => \@extra,
        spacing => exists $opts->{spacing} ? $opts->{spacing} : 1,
    };
    my @footer = @{ $opts->{footer} // [] };
    unless ($opts->{no_status}) {
        push @footer, @{ _menu_status_footer() };
    }
    if (@footer) {
        render_menu_with_footer(menu_context_title($title), $entries, \@footer, $menu_opts);
    }
    else {
        render_menu(menu_context_title($title), $entries, $menu_opts);
    }
}

sub confirm_prompt {
    my ($question, $default) = @_;
    $default = defined $default ? $default : 'n';
    return 0 unless -t STDIN;
    my $prompt_default = (lc($default) eq 'y') ? 'Y/n' : 'y/N';
    while (1) {
        print "$question [$prompt_default]: ";
        my $answer = <STDIN>;
        unless (defined $answer) {
            return lc($default) eq 'y';
        }
        chomp $answer;
        $answer = $default if $answer eq '';
        if ($answer =~ /^(?:y|yes)$/i) {
            return 1;
        }
        if ($answer =~ /^(?:n|no)$/i) {
            return 0;
        }
        print "Please answer yes or no.\n";
    }
}

1;
