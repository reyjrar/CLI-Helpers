#!/usr/bin/env perl
use CLI::Helpers qw(:all);

output({color=>'green'}, "Hello, World!");
verbose({indent=>1,color=>'yellow'}, "Shiny, happy people!");
verbose({level=>2,kv=>1,color=>'red'}, a => 1, b => 2);
debug_var({ c => 3, d => 4});
