package CLI::Helpers;
# ABSTRACT: Subroutines for making simple command line scripts
# RECOMMEND PREREQ: App::Nopaste
# RECOMMEND PREREQ: Term::ReadLine::Gnu

use strict;
use feature qw(state);
use warnings;

use Capture::Tiny qw(capture);
use File::Basename;
use Getopt::Long qw(GetOptionsFromArray);
use IO::Interactive qw( is_interactive );
use JSON::MaybeXS;
use Module::Load qw(load);
use Ref::Util qw(is_ref is_arrayref is_hashref);
use Sys::Syslog qw(:standard);
use Term::ANSIColor 2.01 qw(color colored colorstrip);
use Term::ReadKey;
use Term::ReadLine;
use YAML::XS ();

# VERSION

# Capture ARGV at Load
my @ORIG_ARGS;
BEGIN {
    @ORIG_ARGS = @ARGV;
}

=head1 EXPORT

This module exports the C<:all> group by default.

=head2 Export Groups

Optionally, you can specify the groups you prefer:

=over 2

=item B<:output>

    output()
    verbose()
    debug()
    debug_var()

=item B<:input>

    menu()
    text_input()
    confirm()
    prompt()
    pwprompt()

=item B<:all>

    :output
    :input

=back

All groups include these functions:

    cli_helpers_initialize()
    options_description()

=head2 Configuration

It's possible to change the behavior of the import process.

=over 2

=item B<copy_argv>

Instead of messing with C<@ARGV>, operate on a copy of C<@ARGV>.

    use CLI::Helpers qw( :output copy_argv );

=item B<preprocess_argv>

This causes the C<@ARGV> processing to happen during the C<INIT> phase, after
import but before runtime. This is usually OK for scripts, but for use in
libraries, it may be undesirable. This is the default when C<CLI::Helpers> is
imported from the C<main> package.

    use CLI::Helpers qw( :output preprocess_argv );

=item B<delay_argv>

This causes the C<@ARGV> processing to happen when the first call to a function
needing it run, usually an C<output()> call. This is the default when import
from any other package other than C<main>.

    use CLI::Helpers qw( :output delay_argv );

=back

=cut

require Exporter;
our @ISA = qw(Exporter);

my @export_output = qw(output verbose debug debug_var);
my @export_input  = qw(prompt menu text_input confirm pwprompt);
my @export_always = qw(cli_helpers_initialize options_description);

our @EXPORT_OK = ( @export_output, @export_input, @export_always );
our %EXPORT_TAGS = (
    all    => [@export_always, @export_input, @export_output],
    input  => [@export_always, @export_input],
    output => [@export_always, @export_output],
);

my $ARGV_AT_INIT    = 0;
my $COPY_ARGV       = 0;
our $_init_complete = 0;

sub import {
    my (@args) = @_;

    my @import = ();
    # We need to process the config options
    my $explicit_argv = 0;
    foreach my $arg ( @args ) {
        if( $arg eq 'delay_argv' ) {
            $ARGV_AT_INIT = 0;
            $explicit_argv++;
        }
        elsif( $arg eq 'preprocess_argv' ) {
            $ARGV_AT_INIT = 1;
            $explicit_argv++;
        }
        elsif( $arg eq 'copy_argv' ) {
            $COPY_ARGV = 1;
        }
        # Not a config option, pass through
        else {
            push @import, $arg;
        }
    }
    if ( $explicit_argv != 1 ) {
        my ($package) = caller;
        $ARGV_AT_INIT = $package eq 'main';
    }

    CLI::Helpers->export_to_level( 1, @import );
}

{
    ## no critic (ProhibitNoWarnings)
    no warnings;
    INIT {
        return if $_init_complete++;
        cli_helpers_initialize() if $ARGV_AT_INIT;
    }
    ## use critic
}

=head1 ARGS

From CLI::Helpers:

    --data-file         Path to a file to write lines tagged with 'data => 1'
    --tags              A comma separated list of tags to display
    --color             Boolean, enable/disable color, default use git settings
    --verbose           Incremental, increase verbosity (Alias is -v)
    --debug             Show developer output
    --debug-class       Show debug messages originating from a specific package, default: main
    --quiet             Show no output (for cron)
    --syslog            Generate messages to syslog as well
    --syslog-facility   Default "local0"
    --syslog-tag        The program name, default is the script name
    --syslog-debug      Enable debug messages to syslog if in use, default false
    --nopaste           Use App::Nopaste to paste output to configured paste service
    --nopaste-public    Defaults to false, specify to use public paste services
    --nopaste-service   Comma-separated App::Nopaste service, defaults to Shadowcat

=head1 NOPASTE

This is optional and will only work if you have L<App::Nopaste> installed.  If
you just specify C<--nopaste>, any output that would be displayed to the screen
is submitted to the L<App::Nopaste::Service::Shadowcat> paste bin.  This
paste service is pretty simple, but works reliably.

During the C<END> block, the output is submitted and the URL of the paste is
returned to the user.

=cut

my %OPTIONS = (
    color => {
        description => "Enable colorized output",
        reversible => 1,
    },
    'data-file' => {
        description => "Filename for output tagged as data",
        format => "s",
    },
    debug => {
        description => "Show developer output",
    },
    'debug-class' => {
        description => "Show developer output for a specific class",
        format => "s",
    },
    nopaste => {
        description => "Paste output to configured paste service",
    },
    'nopaste-public' => {
        description => "Must be set to use public paste services",
    },
    'nopaste-service' => {
        description => "Comma-separated App::Nopaste services",
        format => "s",
    },
    quiet => {
        description => "Suppress output to STDERR and STDOUT",
    },
    syslog => {
        description => "Generate messages to syslog as well",
    },
    'syslog-debug' => {
        description => "Enable debug messages to syslog if in use",
    },
    'syslog-facility' => {
        description => "Syslog facility, defaults to 'local0'",
        format => "s",
    },
    'syslog-tag' => {
        description => "Syslog program name, defaults to script name",
        format => "s",
    },
    tags => {
        description => "A comma separated list of tags to display",
        format => "s",
    },
    verbose => {
        aliases => [qw(v)],
        description => "Incremental, increase verbosity output",
        incremental => 1,
    },
);

sub _parse_options {
    my ($opt_ref) = @_;
    my @opt_spec;

    foreach my $opt (sort keys %OPTIONS) {
        my $def = $OPTIONS{$opt};
        my $spec = join("|", $opt, $def->{aliases} ? @{ $def->{aliases} } : ());
        if ( $def->{format} ) {
            $spec .= "=$def->{format}";
        } elsif ( $def->{incremental} ) {
            $spec .= "+";
        } elsif ( $def->{reversible} ) {
            $spec .= "!";
        }
        push @opt_spec, $spec;
    }

    my $argv;
    my %opt;
    if( defined $opt_ref && is_arrayref($opt_ref) ) {
        # If passed an argv array, use that
        $argv = $COPY_ARGV ? [ @{ $opt_ref } ] : $opt_ref;
    }
    else {
        $argv = $COPY_ARGV ? [ @ARGV ] : \@ARGV;
    }
    # Set pass_through and save previous settings
    my $prev = Getopt::Long::Configure('pass_through');
    eval {
        GetOptionsFromArray($argv, \%opt, @opt_spec );
    } or do {
        my $err = $@;
        warn "CLI::Helpers::_parse_options failed: $err";
    };
    # Restore previous settings
    Getopt::Long::Configure($prev);
    return \%opt;
}

my $DATA_HANDLE = undef;
sub _open_data_file {
    my $data_file = shift;
    eval {
        open($DATA_HANDLE, '>', $data_file) or die "data file unwritable: $!";
        1;
    } or do {
        my $error = $@;
        output({color=>'red',stderr=>1}, "Attempted to write to $data_file failed: $!");
    };
}


# Set defaults
my %DEF     = ();
my $TERM    = undef;
my @STICKY  = ();
my @NOPASTE = ();
my %TAGS    = ();

=func cli_helpers_initialize()

This is called automatically when C<preprocess_argv> is set. By default, it'll
be run the first time a definition is needed, usually the first call to
C<output()>.  If called automatically, it will operate on C<@ARGV>.  You can
optionally pass an array reference to this function and it'll operate that
instead.

In most cases, you don't need to call this function directly.

    #!perl
    # Normal use from main package in a script
    use v5.42;
    use CLI::Helpers qw( :output );

    ...
    # CLI::Helpers has already stripped its args from @ARGV
    my %opts = get_important_things_from(\@ARGV);

    output("ready");

This is the same as specifying C<preprocess_argv> from the C<main> package.

    use CLI::Helpers qw( :output preprocess_argv );

    ...
    # Since CLI::Helpers opts are stripped from @ARGV,
    #  Getopt::Long::Descriptive won't complain about extra args
    my ($opt,$usage) = describe_option( ... );

    # Now, let CLI::Helpers take the rest, implicit
    #   call to cli_helpers_initialize()
    output("ready");

Or if you'd prefer not to touch C<@ARGV> at all, you pass in an array ref:

    use CLI::Helpers qw( :output delay_argv );

    my ($opt,$usage) = describe_option( ... );

    cli_helpers_initialize([ qw( --verbose ) ]);

    output("ready?");
    verbose("you bet I am");

=cut

sub cli_helpers_initialize {
    my ($argv) = @_;

    state $defaults = _parse_options() unless $argv;
    my $opts = $argv ? _parse_options($argv) : $defaults;
    _open_data_file($opts->{'data-file'}) if $opts->{'data-file'};

    # Initialize Global Definitions
    %DEF = (
        DEBUG           => $opts->{debug}   || 0,
        DEBUG_CLASS     => $opts->{'debug-class'} || 'main',
        ENCODE          => lc($opts->{encode}  || 'json'),
        VERBOSE         => $opts->{verbose} || 0,
        KV_FORMAT       => ': ',
        QUIET           => $opts->{quiet}   || 0,
        SYSLOG          => $opts->{syslog}  || 0,
        SYSLOG_TAG      => exists $opts->{'syslog-tag'}      && length $opts->{'syslog-tag'}      ? $opts->{'syslog-tag'} : basename($0),
        SYSLOG_FACILITY => exists $opts->{'syslog-facility'} && length $opts->{'syslog-facility'} ? $opts->{'syslog-facility'} : 'local0',
        SYSLOG_DEBUG    => $opts->{'syslog-debug'}  || 0,
        TAGS            => $opts->{tags} ? { map { $_ => 1 } split /,/, $opts->{tags} } : undef,
        NOPASTE         => $opts->{nopaste} || 0,
        NOPASTE_SERVICE => $opts->{'nopaste-service'},
        NOPASTE_PUBLIC  => $opts->{'nopaste-public'},
    );
    $DEF{COLOR} = $opts->{color} // git_color_check();
    $DEF{ENCODE} = 'json' unless $DEF{ENCODE} eq 'json' or $DEF{ENCODE} eq 'yaml';

    debug("DEFINITIONS");
    debug_var(\%DEF);

    # Setup the Syslog Subsystem
    if( $DEF{SYSLOG} ) {
        eval {
            openlog($DEF{SYSLOG_TAG}, 'ndelay,pid', $DEF{SYSLOG_FACILITY});
            1;
        } or do {
            my $error = $@;
            $DEF{SYSLOG}=0;
            output({stderr=>1,color=>'red'}, "CLI::Helpers could not open syslog: $error");
        };
    }

    # Optionally Attempt Loading App::NoPaste
    if( $DEF{NOPASTE} ) {
        eval {
            load 'App::Nopaste';
            1;
        } or do {
            $DEF{NOPASTE} = 0;
            output({stderr=>1,color=>'red',sticky=>1},
                'App::Nopaste is not installed, please cpanm App::Nopaste for --nopaste support',
            );
        };
    }

    return 1;
}


# Allow some messages to be fired at the end the of program
END {
    # Show discovered tags
    if( keys %TAGS ) {
        output({color=>'cyan',stderr=>1},
            sprintf "# Tags discovered: %s",
                join(', ', map { "$_=$TAGS{$_}" } sort keys %TAGS)
        );
    }
    # Show Sticky Output
    if(@STICKY) {
        foreach my $args (@STICKY) {
            output(@{ $args });
        }
    }
    # Do the Nopaste
    if( @NOPASTE ) {
        my $command_string = join(" ", $0, @ORIG_ARGS);
        unshift @NOPASTE, "\$ $command_string";
        # Figure out what services to use
        my $services = $DEF{NOPASTE_SERVICE}  ? [ split /,/, $DEF{NOPASTE_SERVICE} ]
                     : $ENV{NOPASTE_SERVICES} ? [ split /,/, $ENV{NOPASTE_SERVICES} ]
                     :  undef;
        my %paste = (
            text     => join("\n", @NOPASTE),
            summary  => $command_string,
            desc     => $command_string,
            # Default to a Private Paste
            private  => $DEF{NOPASTE_PUBLIC} ? 0 : 1,
        );
        debug_var(\%paste);
        if( $services ) {
            output({color=>'cyan',stderr=>1}, "# NoPaste: "
                . App::Nopaste->nopaste(%paste, services => $services)
            );
        }
        else {
            output({color=>'red',stderr=>1,clear=>1},
                "!! In order to use --nopaste, you need to your environment variable",
                "!! NOPASTE_SERVICES or pass --nopaste-service, e.g.:",
                "!!   export NOPASTE_SERVICES=Shadowcat,PastebinCom");
        }
    }
    closelog() if $DEF{SYSLOG};
}

=func options_description()

Returns an array of arrayrefs to use with L<Getopt::Long::Descriptive>.

    use CLI::Helpers qw( option_description );
    use Getopt::Long::Descriptive qw( describe_options );

    my ($opt,$usage) = describe_options("%c %o",
        # Your opts here
        options_description(),
    );

=cut

sub options_description {
    my @description = (
        [],
        ["CLI::Helpers Options"],
    );

    my(@opt,@desc);
    my $opt_width = 0;
    foreach my $opt ( sort keys %OPTIONS ) {
        my $def = $OPTIONS{$opt};
        my $desc = sprintf "--%s", $opt;
        if ( $def->{aliases} ) {
            $desc .= ' (';
            foreach my $alias ( @{ $def->{aliases} } ) {
                $desc .= sprintf "or %s%s", length($alias) > 1 ? '--' : '-', $alias;
            }
            $desc .= ')';
        }
        push @opt, $desc;
        $opt_width = length($desc) if length($desc) > $opt_width;
        push @desc, $def->{description};
        if ( $def->{reversible} ) {
            push @opt, sprintf "--no%s", $opt;
            push @desc, $def->{description} =~ s/Enable/Disable/r;
        }
    }

    while( @opt && @desc ) {
        push @description, [sprintf "%-${opt_width}s  %s", shift(@opt), shift(@desc) ];
    }

    return @description;
}

=func colorize( $color => 'message to be output' )

Not exported by default.  Checks if color is enabled and applies
the specified color to the string.

=cut

sub colorize {
    my ($color,$string) = @_;

   if( defined $color && $DEF{COLOR} ) {
        $string=colored([ $color ], $string);
    }
    return $string;
}

=func git_color_check()

Not exported by default.  Returns 1 if git is configured to output
using color of 0 if color is not enabled.

=cut

sub git_color_check {
    return unless is_interactive();

    my @cmd = qw(git config --global --get color.ui);
    my($stdout,$stderr,$rc) = capture {
        system @cmd;
    };
    if( $rc != 0 ) {
        debug("git_color_check error: $stderr");
        return 0;
    }
    debug("git_color_check out: $stdout");
    if( $stdout =~ /auto/ || $stdout =~ /true/ ) {
        return 1;
    }

    return 0;
}

=func def($key)

Not exported by default, returns the setting defined.

=cut

sub def { return exists $DEF{$_[0]} ? $DEF{$_[0]} : undef }

=output output( \%opts, @messages )

Exported.  Takes an optional hash reference and a list of
messages to be output.

Any data references in the the C<@messages> list will automatically be converted to JSON. You may also pass

    { yaml => 1 }

In the options to output in YAML format.

=cut

my %_valid_opts = map { $_ => 1 } qw(_caller_package clear color data encode indent json kv level no_syslog stderr sticky syslog_level tag yaml);
sub _output_args {
    my @args = @_;

    return unless @args;

    if ( @args == 1 ) {
        return {}, $args[0];
    }

    if ( is_hashref($args[0]) ) {
        my $invalid = 0;
        foreach my $k ( keys %{ $args[0] } ) {
            next if exists $_valid_opts{$k};
            $invalid = 1;
            last;
        }
        return {}, @args if $invalid;
    }

    return @args;
}

sub output {
    my ($opts,@lines) = _output_args(@_);

    state $json = JSON->new->canonical->utf8->allow_blessed->convert_blessed;

    # Return unless we have something to work with;
    return unless @lines;

    # Ensure we're all setup
    cli_helpers_initialize() unless keys %DEF;

    # Input/output Arrays
    my $encode = sub { $DEF{ENCODE} eq 'yaml' || $opts->{yaml} ? YAML::XS::Dump($_[0]) : $json->encode($_[0]) };
    my @input  = map { my $x=$_; chomp($x) if defined $x; $x; }
                 map { defined $_ && ref $_ ? $encode->($_) : $_ } @lines;
    my @output = ();

    # Determine the color
    my $color = exists $opts->{color} && defined $opts->{color} ? $opts->{color} : undef;

    # Determine indentation
    my $indent = exists $opts->{indent} ? " "x(2*$opts->{indent}) : '';

    # If tagged, we only output if the tag is requested
    if( $DEF{TAGS} && exists $opts->{tag} ) {
        # Skip this altogether
        $TAGS{$opts->{tag}} ||= 0;
        $TAGS{$opts->{tag}}++;
        return unless $DEF{TAGS}->{$opts->{tag}};
    }

    # Determine if we're doing Key Value Pairs
    my $DO_KV = (scalar(@input) % 2 == 0 ) && (exists $opts->{kv} && $opts->{kv} == 1) ? 1 : 0;

    if( $DO_KV ) {
        while( @input ) {
            my $k = shift @input;
            # We only colorize the value
            my $v = shift @input;
            $v ||= $DEF{KV_FORMAT} eq ': ' ? '~' : '';
            push @output, join($DEF{KV_FORMAT}, $k, colorize($color,$v));
        }
    }
    else {
        @output = map { colorize($color, $_) } @input;
    }

    # Out to the console
    if( !$DEF{QUIET} || $opts->{IMPORTANT} ) {
        my $out_handle = $opts->{stderr} ? \*STDERR : \*STDOUT;
        # Do clearing
        print $out_handle "\n"x$opts->{clear} if exists $opts->{clear};
        # Print output
        print $out_handle "${indent}$_\n" for @output;
    }

    # Handle data, which is raw
    if(defined $DATA_HANDLE && $opts->{data}) {
        print $DATA_HANDLE "$_\n" for @input;
    }
    elsif( $DEF{SYSLOG} && !$opts->{no_syslog}) {
        my $level = exists $opts->{syslog_level} ? $opts->{syslog_level} :
                    exists $opts->{stderr}       ? 'err' :
                    'notice';

        # Warning for syslogging data file
        unshift @output, "CLI::Helpers logging a data section, use --data-file to suppress this in syslog."
            if $opts->{data};

        # Now syslog the message
        debug({no_syslog=>1,color=>'magenta'}, sprintf "[%s] Syslogging %d messages, with: %s", $level, scalar(@output), join(",", map { $_=>$opts->{$_} } keys %{ $opts }));
        for( @output ) {
            # One bad message means no more syslogging
            eval {
                syslog($level, colorstrip($_));
                1;
            } or do {
                my $error = $@;
                $DEF{SYSLOG} = 0;
                output({stderr=>1,color=>'red',no_syslog=>1}, "syslog() failed: $error");
            };
        }
    }

    # Sticky messages don't just go away
    if(exists $opts->{sticky}) {
        my %o = %{ $opts };  # Make a copy because we shifted this off @_
        # So this doesn't happen in the END block again
        delete $o{$_} for grep { exists $o{$_} } qw(sticky data);
        $o{no_syslog} = 1;
        push @STICKY, [ \%o, @input ];
    }
    if( $DEF{NOPASTE} ) {
        push @NOPASTE, map { $indent . colorstrip($_) } @output;
    }
}

=output verbose( \%opts, @messages )

Exported.  Takes an optional hash reference of formatting options.  Automatically
overrides the B<level> parameter to 1 if it's not set.

=cut

sub verbose {
    my $opts = is_hashref($_[0]) ? shift @_ : {};
    $opts->{level} = 1 unless exists $opts->{level};
    $opts->{syslog_level} = $opts->{level} > 1 ? 'debug' : 'info';
    my @msgs=@_;

    # Ensure we're all configured
    cli_helpers_initialize() unless keys %DEF;

    if( !$DEF{DEBUG} ) {
        return unless $DEF{VERBOSE} >= $opts->{level};
    }
    output( $opts, @msgs );
}

=output debug( \%opts, @messages )

Exported.  Takes an optional hash reference of formatting options.
Does not output anything unless DEBUG is set.

=cut

sub debug {
    my $opts = is_hashref($_[0]) ? shift @_ : {};
    my @msgs=@_;

    # Ensure we're all configured
    cli_helpers_initialize() unless keys %DEF;

    # Smarter handling of debug output
    return unless $DEF{DEBUG};

    # Check against caller class
    my $package = exists $opts->{_caller_package} ? $opts->{_caller_package} : (caller)[0];
    return unless lc $DEF{DEBUG_CLASS} eq 'all' || $package eq $DEF{DEBUG_CLASS};

    # Check if we really want to debug syslog data
    $opts->{syslog_level} = 'debug';
    $opts->{no_syslog} //= !$DEF{SYSLOG_DEBUG};

    # Output
    output( $opts, @msgs );
}

=output debug_var( \%opts, \%Variable )

Exported.  Takes an optional hash reference of formatting options.
Does not output anything unless DEBUG is set.

Passing:

    { json => 1 }

in C<\%opts> will format the output as JSON

=cut

sub debug_var {
    my $opts = {
        clear           => 1,               # Meant for the screen
        no_syslog       => 1,               # Meant for the screen
        _caller_package => (caller)[0],     # Make sure this is set on entry
    };
    # Merge with options
    if( is_hashref($_[0]) && defined $_[1] && is_ref($_[1]) ) {
        my $ref = shift;
        foreach my $k (keys %{ $ref } ) {
            $opts->{$k} = $ref->{$k};
        };
    }

    my $var = shift;
    debug($opts, $DEF{ENCODE} eq 'json' || $opts->{json} ? $var : YAML::XS::Dump $var);
}

=func override( variable => 1 )

Exported.  Allows a block of code to override the debug or verbose level.  This
can be used during development to enable/disable the DEBUG/VERBOSE settings.

=cut

my %_allow_override = map { $_ => 1 } qw(debug verbose);
sub override {
    my ($var,$value) = @_;

    return unless exists $_allow_override{lc $var};

    my $def_var = uc $var;
    $DEF{$def_var} = $value;
}

=input confirm("prompt")

Exported.  Creates a Yes/No Prompt which accepts y/n or yes/no case insensitively
but requires one or the other.

Returns 1 for 'yes' and 0 for 'no'

=cut

my $_Confirm_Valid;
sub confirm {
    my ($question) = @_;

    # Initialize Globals
    $_Confirm_Valid ||= {qw(y 1 yes 1 n 0 no 0)};

    $question =~ s/\s*$/ [yN] /;
    my $answer = undef;
    until( defined $answer && exists $_Confirm_Valid->{$answer} ) {
        output({color=>'red',stderr=>1},"ERROR: must be one of 'y','n','yes','no'") if defined $answer;
        $answer = lc _get_input($question);
    }
    return $_Confirm_Valid->{$answer};
}

=input text_input("prompt", validate => { "too short" => sub { length $_ > 10 } })

Exported.  Provides a prompt to the user for input.  If validate is passed, it should be a hash reference
containing keys of error messages and values which are subroutines to validate the input available as $_.
If a validator fails, it's error message will be displayed, and the user will be re-prompted.

Valid options are:

=over 4

=item B<default>

Any string which will be used as the default value if the user just presses enter.

=item B<validate>

A hashref, keys are error messages, values are sub routines that return true when the value meets the criteria.

=item B<noecho>

Set as a key with any value and the prompt will turn off echoing responses as well as disabling all
ReadLine magic.  See also B<pwprompt>.

=item B<clear_line>

After prompting for and receiving input, remove that line from the terminal.
This only works on interactive terminals, and is useful for things like
password prompts.

=back

Returns the text that has passed all validators.

=cut

sub text_input {
    my $question = shift;
    my %args = @_;

    # Prompt fixes
    chomp($question);
    my $terminator = $question =~ s/([^a-zA-Z0-9\)\]\}])\s*$// ? $1 : ':';
    if(exists $args{default}) {
        $question .= " (default=$args{default}) ";
    }
    $question .= "$terminator ";

    # Make sure there's a space before the prompt
    $question =~ s/\s*$/ /;
    my $validate = exists $args{validate} ? $args{validate} : {};

    my $text;
    my $error = undef;
    until( defined $text && !defined $error ) {
        output({color=>'red',stderr=>1},"ERROR: $error") if defined $error;

        # Try to have the user answer the question
        $text  = _get_input($question => \%args);
        $error = undef;

        # Check the default if the person just hit enter
        if( exists $args{default} && length($text) == 0 ) {
            return $args{default};
        }
        foreach my $v (keys %{$validate}) {
            local $_ = $text;
            if( $validate->{$v}->() > 0 ) {
                debug({indent=>1}," + Validated: $v");
                next;
            }
            $error = $v;
            last;
        }
    }
    return $text;
}

=input menu("prompt", $ArrayOrHashRef)

Exported.  Used to create a menu of options from a list.  Can be either a hash or array reference
as the second argument.  In the case of a hash reference, the values will be displayed as options while
the selected key is returned.  In the case of an array reference, each element in the list is displayed
the selected element will be returned.

Returns selected element (HashRef -> Key, ArrayRef -> The Element)

=cut

sub menu {
    my ($question,$opts) = @_;
    my %desc = ();

    # Determine how to handle this list
    if( is_arrayref($opts) ) {
        %desc = map { $_ => $_ } @{ $opts };
    }
    elsif( is_hashref($opts) ) {
        %desc = %{ $opts };
    }

    print "$question\n\n";
    my %ref = ();
    my $id  = 0;
    foreach my $key (sort keys %desc) {
        $ref{++$id} = $key;
    }

    my $choice;
    until( defined $choice && exists $ref{$choice} ) {
        output({color=>'red',stderr=>1},"ERROR: invalid selection") if defined $choice;
        foreach my $id (sort { $a <=> $b } keys %ref) {
            printf "    %d. %s\n", $id, $desc{$ref{$id}};
        }
        print "\n";
        $choice = _get_input("Selection (1-$id): ");
    }
    return $ref{$choice};
}

=input pwprompt("Prompt", options )

Exported.  Synonym for text_input("Password: ", noecho => 1);  Also requires the password to be longer than 0 characters.

=cut

sub pwprompt {
    my ($prompt, %args) = @_;
    $prompt ||= "Password: ";
    my @more_validate;
    if (my $validate = $args{validate}){
        @more_validate = %$validate;
    }
    return text_input($prompt,
        noecho     => 1,
        clear_line => 1,
        validate => { "password length can't be zero." => sub { defined && length },
                      @more_validate,
                    },
    );
}

=input prompt("Prompt", options )

Exported.  Wrapper function with rudimentary mimicry of IO::Prompt(er).
Uses:

    # Mapping back to confirm();
    my $value = prompt "Are you sure?", yn => 1;

    # Mapping back to text_input();
    my $value = prompt "Enter something:";

    # With Validator
    my $value = prompt "Enter an integer:", validate => { "not a number" => sub { /^\d+$/ } }

    # Pass to menu();
    my $value = prompt "Select your favorite animal:", menu => [qw(dog cat pig fish otter)];

    # If you request a password, autodisable echo:
    my $passwd = prompt "Password: ";  # sets noecho => 1, disables ReadLine history.

See also: B<text_input>

=cut

sub prompt {
    my ($prompt) = shift;
    my %args = @_;

    return confirm($prompt)           if exists $args{yn};
    return menu($prompt, $args{menu}) if exists $args{menu};
    # Check for a password prompt
    if( lc($prompt) =~ /passw(or)?d/ ) {
        $args{noecho} = 1;
        $args{validate} ||= {};
        $args{validate}->{"password length can't be zero."} = sub { defined && length };
    }
    return text_input($prompt,%args);
}

sub _get_input {
    my ($prompt,$args) = @_;

    state $interactive = is_interactive();
    state $term;

    my $text = '';
    if( $interactive ) {
        # Initialize Term
        $term ||= Term::ReadLine->new($0);
        $args ||= {};
        print "\e[s" if $args->{clear_line}; # Save cursor position
        if( $args->{noecho} ) {
            # Disable all the Term ReadLine magic
            local $|=1;
            print $prompt;
            ReadMode('noecho');
            $text = ReadLine();
            ReadMode('restore');
            print "\n";
            chomp($text);
        }
        else {
            $text = $term->readline($prompt);
            $term->addhistory($text) if length $text && $text =~ /\S/;
        }
        print "\e[u\e[K" if $args->{clear_line}; # Return to saved position, erase line
    }
    else {
        # Read one line from STDIN
        $text = <>;
    }
    return $text;
}

=head1 SYNOPSIS

This module provides a library of useful functions for constructing simple command
line interfaces.  It is able to extract information from the environment and your
~/.gitconfig to display data in a reasonable manner.

    use CLI::Helpers;

    ...
    output({color=>"green"}, "Hello, world!");
    debug({color=>"yellow"}, "Debug output!");

Using this module adds argument parsing using L<Getopt::Long> to your script.  It
enables pass-through, so you can still use your own argument parsing routines or
L<Getopt::Long> in your script.


=head1 EXAMPLE

A simple example of how to use this module and what it does.

=head2 Script

    #!/usr/bin/env perl
    use CLI::Helpers qw(:all);

    output({color=>'green'}, "Hello, World!");
    verbose({indent=>1,color=>'yellow'}, "Shiny, happy people!");
    verbose({level=>2,kv=>1,color=>'red'}, a => 1, b => 2);
    debug_var({ c => 3, d => 4});

    # Data
    output({data=>1}, join(',', qw(a b c d)));

    # Wait for confirmation
    die "ABORTING" unless confirm("Are you sure?");

    # Ask for a number
    my $integer = prompt "Enter an integer:", validate => { "not a number" => sub { /^\d+$/ } }

    # Ask for next move
    my %menu = (
        north => "Go north.",
        south => "Go south.",
    );
    my $dir = prompt "Where to, adventurous explorer?", menu => \%menu;

    # Ask for a favorite animal
    my $favorite = menu("Select your favorite animal:", [qw(dog cat pig fish otter)]);

=head2 Usage

    $ ./test.pl
    Hello, World!
    a,b,c,d
    $ ./test.pl --verbose
    Hello, World!
      Shiny, Happy people!
    a,b,c,d
    $ ./test.pl -vv
    Hello, World!
      Shiny, Happy people!
      a: 1
      b: 2
    a,b,c,d
    $ ./test.pl --debug
    Hello, World!
      Shiny, Happy people!
      a: 1
      b: 2
    ---
    c: 3
    d: 4
    a,b,c,d

    $ ./test.pl --data-file=output.csv
    Hello, World!
    a,b,c,d
    $ cat output.csv
    a,b,c,d


Colors would be automatically enabled based on the user's ~/.gitconfig

=head1 OUTPUT OPTIONS

Every output function takes an optional HASH reference containing options for
that output.  The hash may contain the following options:

=over 4

=item B<tag>

Add a keyword to tag output with.  The user may then specify C<--tags
keyword1,keyword2> to only view output at the appropriate level.  This option
will affect C<data-file> and C<syslog> output.  The output filter requires both
the presence of the C<tag> in the output options B<and> the user to specify
C<--tags> on the command line.

Consider a script, C<status.pl>:

    output("System Status: Normal")
    output({tag=>'foo'}, "Component Foo: OK");
    output({tag=>'bar'}, "Component Bar: OK");

If an operator runs:

    $ status.pl
    System Status: Normal
    Component Foo: OK
    Component Bar: OK

    $ status.pl --tags bar
    System Status: Normal
    Component Bar: OK

    $ status.pl --tags foo
    System Status: Normal
    Component Foo: OK

This could be helpful for selecting one or more pertinent tags to display.

=item B<sticky>

Any lines tagged with 'sticky' will be replayed at the end program's end.  This
is to allow a developer to ensure message are seen at the termination of the program.

=item B<color>

String. Using Term::ANSIColor for output, use the color designated, i.e.:

    red,blue,green,yellow,cyan,magenta,white,black, etc..

=item B<level>

Integer. For verbose output, this is basically the number of -v's necessary to see
this output.

=item B<syslog_level>

String.  Can be any valid syslog_level as a string: debug, info, notice, warning, err, crit,
alert, emerg.

=item B<no_syslog>

Bool.  Even if the user specifies --syslog, these lines will not go to the syslog destination.
alert, emerg.

=item B<IMPORTANT>

Bool. Even if --quiet is specified, output this message.  Use sparingly, and yes,
it is case sensitive.  You need to yell at it for it to yell at your users.

=item B<stderr>

Bool. Use STDERR for this message instead of STDOUT.  The advantage to using this is the
"quiet" option will silence these messages as well.

=item B<indent>

Integer.  This will indent by 2 times the specified integer the next string.  Useful
for creating nested output in a script.

=item B<clear>

Integer.  The number of newlines before this output.

=item B<kv>

Bool.  The array of messages is actually a key/value pair, this implements special coloring and
expects the number of messages to be even.

    output(qw(a 1 b 2));
    # a
    # 1
    # b
    # 2

Using kv, the output will look like this:

    output({kv=>1}, qw(a 1 b 2));
    # a: 1
    # b: 2
    #

=item B<data>

Bool.  Lines tagged with "data => 1" will be output to the data-file if a user specifies it.  This allows
you to provide header/footers and inline context for the main CLI, but output just the data to a file for
piping elsewhere.

=back

=cut


# Return True
1;
