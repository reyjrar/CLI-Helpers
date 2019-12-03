use strict;
use warnings;
use CLI::Helpers qw(:output copy_argv);

output({color=>'cyan'}, sprintf '@ARGV contains: %s',
    join(', ', map { "'$_'" } @ARGV)
);
