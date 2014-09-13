# ABSTRACT: Subroutines for making simple command line scripts
package CLI::Helpers;

our $VERSION = 0.6;
our $_OPTIONS_PARSED;

use strict;
use warnings;

use IPC::Run3;
use Term::ANSIColor;
use Term::ReadLine;
use YAML;
use Getopt::Long qw(:config pass_through);

{ # Work-around for CPAN Smoke Test Failure
    # Details: http://perldoc.perl.org/5.8.9/Term/ReadLine.html#CAVEATS
    open( my $FH, "/dev/tty" )
        or eval 'sub Term::ReadLine::findConsole { ("&STDIN", "&STDERR") }';
    die $@ if $@;
    close $FH;
} # End Work-around

=head1 EXPORT

This module uses L<Sub::Exporter> for flexible imports, the defaults provided by
:all are as follows.

=head2 Exported Functions

    output  ( \%options, @messages )
    verbose ( \%options, @messages )
    debug   ( \%options, @messages )
    debug_var ( \$var )
    override( option => $value )

    menu       ( "Question", \%Options or \@Options )
    text_input ( "Question", validate => { "error message" => sub { length $_[0] } } )
    confirm    ( "Question" )

    prompt()    Wrapper which mimicks IO::Prompt a bit

=cut

use Sub::Exporter -setup => {
    exports => [qw(
        output verbose debug debug_var override
        prompt confirm text_input menu
    )],
    groups => {
        input  => [qw(prompt menu text_input confirm)],
        output => [qw(output verbose debug debug_var)],
    }
};

=head1 ARGS

From CLI::Helpers:

    --data-file         Path to a file to write lines tagged with 'data => 1'
    --color             Boolean, enable/disable color, default use git settings
    --verbose           Incremental, increase verbosity (Alias is -v)
    --debug             Show developer output
    --quiet             Show no output (for cron)

=cut

my %opt = ();
if( !defined $_OPTIONS_PARSED ) {
    GetOptions(\%opt,
        'color!',
        'verbose|v+',
        'debug',
        'quiet',
        'data-file:s',
    );
    $_OPTIONS_PARSED = 1;
}

my $data_fh = undef;
if( exists $opt{'data-file'} ) {
    eval {
        open($data_fh, '>', $opt{'data-file'}) or die "data file unwritable: $!";
    };
    if( my $error = $@ ) {
        output({color=>'red',stderr=>1}, "Attempted to write to $opt{'data-file'} failed: $!");
    }
}

# Set defaults
my %DEF = (
    DEBUG       => $opt{debug}   || 0,
    VERBOSE     => $opt{verbose} || 0,
    COLOR       => $opt{color}   || git_color_check(),
    KV_FORMAT   => ': ',
    QUIET       => $opt{quiet}   || 0,
);
debug_var(\%DEF);


my $TERM = undef;
my @STICKY = ();

# Allow some messages to be fired at the end the of program
END {
    if(@STICKY) {
        foreach my $args (@STICKY) {
            output(@{ $args  });
        }
    }
}

=func def

Not exported by default, returns the setting defined.

=cut

sub def { return exists $DEF{$_[0]} ? $DEF{$_[0]} : undef }

=func git_color_check

Not exported by default.  Returns 1 if git is configured to output
using color of 0 if color is not enabled.

=cut

sub git_color_check {
    my @cmd = qw(git config --global --get color.ui);
    my($out,$err);
    eval {
        run3(\@cmd, undef, \$out, \$err);
    };
    if( $@  || $err ) {
        my $error = defined $err ? $err : '';
        $error   .= defined $@   ? " $@" : '';
        debug("git_color_check error: $error");
        return 0;
    }
    debug("git_color_check out: $out");
    if( $out =~ /auto/ || $out =~ /true/ ) {
        return 1;
    }
    return 0;
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

=func output( \%opts, @messages )

Exported.  Takes an optional hash reference and a list of
messages to be output.

=cut

sub output {
    my $opts = ref $_[0] eq 'HASH' ? shift @_ : {};

    # Quiet mode!
    return if $DEF{QUIET};

    # Input/output Arrays
    my @input = @_;
    my @output = ();

    # Remove line endings
    chomp(@input);

    # Determine the color
    my $color = exists $opts->{color} && defined $opts->{color} ? $opts->{color} : undef;

    # Determine indentation
    my $indent = exists $opts->{indent} ? " "x(2*$opts->{indent}) : '';

    # Determine if we're doing Key Value Pairs
    my $DO_KV = (scalar(@input) % 2 == 0 ) && (exists $opts->{kv} && $opts->{kv} == 1) ? 1 : 0;

    if( $DO_KV ) {
        while( @input ) {
            my $k = shift @input;
            # We only colorize the value
            my $v = colorize($color, shift @input );
            push @output, join($DEF{KV_FORMAT}, $k, $v);
        }
    }
    else {
        foreach my $msg ( map { colorize($color, $_); } @input) {
            push @output, $msg;
        }
    }
    my $out_handle = exists $opts->{stderr} && $opts->{stderr} ? \*STDERR : \*STDOUT;
    # Do clearing
    print $out_handle "\n"x$opts->{clear} if exists $opts->{clear};
    # Print output
    print $out_handle "${indent}$_\n" for @output;

    # Handle data, which is raw
    if(defined $data_fh && exists $opts->{data} && $opts->{data}) {
        print $data_fh "$_\n" for @input;
    }

    # Sticky messages don't just go away
    if(exists $opts->{sticky}) {
        my %o = %{ $opts };  # Make a copy because we shifted this off @_
        # So this doesn't happen in the END block again
        delete $o{$_} for grep { exists $o{$_} } qw(sticky data);
        push @STICKY, [ \%o, @input ];
    }
}
=func verbose( \%opts, @messages )

Exported.  Takes an optional hash reference of formatting options.  Automatically
overrides the B<level> paramter to 1 if it's not set.

=cut

sub verbose {
    my $opts = ref $_[0] eq 'HASH' ? shift @_ : {};
    $opts->{level} = 1 unless exists $opts->{level};
    my @msgs=@_;

    if( !$DEF{DEBUG} ) {
        return unless $DEF{VERBOSE} >= $opts->{level};
    }
    output( $opts, @msgs );
}

=func debug( \%opts, @messages )

Exported.  Takes an optional hash reference of formatting options.
Does not output anything unless DEBUG is set.

=cut

sub debug {
    my $opts = ref $_[0] eq 'HASH' ? shift @_ : {};
    my @msgs=@_;
    return unless $DEF{DEBUG};
    output( $opts, @msgs );
}

=func debug_var( \%opts, \%Variable )

Exported.  Takes an optional hash reference of formatting options.
Does not output anything unless DEBUG is set.

=cut

sub debug_var {
    return unless $DEF{DEBUG};

    my $opts = {clear => 1};
    if( ref $_[0] eq 'HASH' && defined $_[1] && ref $_[1] ) {
        my $ref = shift;
        foreach my $k (keys %{ $ref } ) {
            $opts->{$k} = $ref->{$k};
        };
    }
    output( $opts, Dump shift);
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

=func confirm("prompt")

Exported.  Creates a Yes/No Prompt which accepts y/n or yes/no case insensitively
but requires one or the other.

Returns 1 for 'yes' and 0 for 'no'

=cut

my $_Confirm_Valid;
sub confirm {
    my ($question) = @_;

    # Initialize Globals
    $TERM ||= Term::ReadLine->new($0);
    $_Confirm_Valid ||= {qw(y 1 yes 1 n 0 no 0)};

    $question =~ s/\s*$/ [yN] /;
    my $answer = undef;
    until( defined $answer && exists $_Confirm_Valid->{$answer} ) {
        output({color=>'red',stderr=>1},"ERROR: must be one of 'y','n','yes','no'") if defined $answer;
        $answer = lc $TERM->readline($question);
    }
    return $_Confirm_Valid->{$answer};
}

=func text_input("prompt", validate => { "too short" => sub { length $_ > 10 } })

Exported.  Provides a prompt to the user for input.  If validate is passed, it should be a hash reference
containing keys of error messages and values which are subroutines to validate the input available as $_.
If a validator fails, it's error message will be displayed, and the user will be reprompted.

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

    # Initialize Term
    $TERM ||= Term::ReadLine->new($0);

    # Make sure there's a space before the prompt
    $question =~ s/\s*$/ /;
    my $OUT = $TERM->OUT || \*STDOUT;
    my $validate = exists $args{validate} ? $args{validate} : {};

    my $text;
    my $error = undef;
    until( defined $text && !defined $error ) {
        output({color=>'red',stderr=>1},"ERROR: $error") if defined $error;

        # Try to have the user answer the question
        $error=undef;
        $text = $TERM->readline($question);
        $TERM->addhistory($text) if $text =~ /\S/;

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

=func menu("prompt", $ArrayOrHashRef)

Exported.  Used to create a menu of options from a list.  Can be either a hash or array reference
as the second argument.  In the case of a hash reference, the values will be displayed as options while
the selected key is returned.  In the case of an array reference, each element in the list is displayed
the selected element will be returned.

Returns selected element (HashRef -> Key, ArrayRef -> The Element)

=cut

sub menu {
    my ($question,$opts) = @_;
    my %desc = ();

    # Initialize Term
    $TERM ||= Term::ReadLine->new($0);

    # Determine how to handle this list
    if( ref $opts eq 'ARRAY' ) {
        %desc = map { $_ => $_ } @{ $opts };
    }
    elsif( ref $opts eq 'HASH' ) {
        %desc = %{ $opts };
    }
    my $OUT = $TERM->OUT || \*STDOUT;

    print $OUT "$question\n\n";
    my %ref = ();
    my $id  = 0;
    foreach my $key (sort keys %desc) {
        $ref{++$id} = $key;
    }

    my $choice;
    until( defined $choice && exists $ref{$choice} ) {
        output({color=>'red',stderr=>1},"ERROR: invalid selection") if defined $choice;
        foreach my $id (sort { $a <=> $b } keys %ref) {
            printf $OUT "    %d. %s\n", $id, $desc{$ref{$id}};
        }
        print $OUT "\n";
        $choice = $TERM->readline("Selection (1-$id): ");
        $TERM->addhistory($choice) if $choice =~ /\S/;
    }
    return $ref{$choice};
}

=func prompt("Prompt", options )

Exported.  Wrapper function with rudimentary mimickery of IO::Prompt(er).
Uses:

    # Mapping back to confirm();
    my $value = prompt "Are you sure?", yn => 1;

    # Mapping back to text_input();
    my $value = prompt "Enter something:";

    # With Validator
    my $value = prompt "Enter an integer:", validate => { "not a number" => sub { /^\d+$/ } }

    # Pass to menu();
    my $value = prompt "Select your favorite animal:", menu => [qw(dog cat pig fish otter)];

=cut

sub prompt {
    my ($prompt) = shift;
    my %args = @_;

    return confirm($prompt) if exists $args{yn};
    return menu($prompt, $args{menu}) if exists $args{menu};
    return text_input($prompt,%args);
}

=head1 SYNOPSIS

Use this module to make writing intelligent command line scripts easier.

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

Running as test.pl:

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

=head1 OVERVIEW

This module provides a libray of useful functions for constructing simple command
line interfaces.  It is able to extract information from the environment and your
~/.gitconfig to display data in a reasonable manner.

Using this module adds argument parsing using L<Getopt::Long> to your script.  It
enables passthrough, so you can still use your own argument parsing routines or
Getopt::Long in your script.

=head1 OUTPUT OPTIONS

Every output function takes an optional HASH reference containing options for
that output.  The hash may contain the following options:

=over 4

=item B<sticky>

Any lines tagged with 'sticky' will be replayed at the end program's end.  This
is to allow a developer to ensure message are seen at the termination of the program.

=item B<color>

String. Using Term::ANSIColor for output, use the color designated, ie:

    red,blue,green,yellow,cyan,magenta,white,black, etc..

=item B<level>

Integer. For verbose output, this is basically the number of -v's necessary to see
this output.

=item B<stderr>

Bool. Use STDERR for this message instead of STDOUT.  The advantage to using this is the
"quiet" option will silence these messages as well.

=item B<indent>

Integer.  This will indent by 2 times the specified integer the next string.  Useful
for creating nested output in a script.

=item B<clear>

Integer.  The number of newlines before this output.

=item B<kv>

Bool.  The array of messsages is actually a key/value pair, this implements special coloring and
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
