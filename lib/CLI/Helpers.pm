# ABSTRACT: Subroutines for making simple command line scripts
package CLI::Helpers;

our $VERSION = 0.2;
our $_OPTIONS_PARSED;

use strict;
use warnings;

use IPC::Run3;
use Term::ANSIColor;
use YAML;
use Getopt::Long qw(:config pass_through);

=head1 EXPORT

This module uses L<Sub::Exporter> for flexible imports, the defaults provided by
:all are as follows.

=head2 Exported Functions

    output  ( \%options, @messages )
    verbose ( \%options, @messages )
    debug   ( \%options, @messages )
    debug_var ( \$var )
    override( option => $value )

=cut

use Sub::Exporter -setup => {
    exports => [
        qw(output verbose debug debug_var override)
    ],
};

=head1 ARGS

From CLI::Helpers:

    --color             Boolean, enable/disable color, default use git settings
    --verbose           Incremental, increase verbosity
    --debug             Show developer output
    --quiet             Show no output (for cron)

=cut

my %opt = ();
if( !defined $_OPTIONS_PARSED ) {
    GetOptions(\%opt,
        'color!',
        'verbose+',
        'debug',
        'quiet',
    );
    $_OPTIONS_PARSED = 1;
}
# Set defaults
my %DEF = (
    DEBUG       => $opt{debug} || 0,
    VERBOSE     => $opt{verbose} || 0,
    COLOR       => $opt{color} || git_color_check(),
    KV_FORMAT   => ': ',
    QUIET       => $opt{quiet} || 0,
);
debug_var(\%DEF);

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
        debug("git_color_check error: $err ($@)");
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

=head1 SYNOPSIS

Use this module to make writing intelligent command line scripts easier.

    #!/usr/bin/env perl
    use CLI::Helpers qw(:all);

    output({color=>'green'}, "Hello, World!");
    verbose({indent=>1,color=>'yellow'}, "Shiny, happy people!");
    verbose({level=>2,kv=>1,color=>'red'}, a => 1, b => 2);
    debug_var({ c => 3, d => 4});

Running as test.pl:

    $ ./test.pl
    Hello, World!
    $ ./test.pl --verbose
    Hello, World!
      Shiny, Happy people!
    $ ./test.pl -vv
    Hello, World!
      Shiny, Happy people!
      a: 1
      b: 2
    $ ./test.pl --debug
    Hello, World!
      Shiny, Happy people!
      a: 1
      b: 2
    ---
    c: 3
    d: 4

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

=back

=cut


# Return True
1;
