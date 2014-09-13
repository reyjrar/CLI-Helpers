#!/usr/bin/env perl
#
use strict;
use warnings;
use CLI::Helpers qw(:all);

my $v = prompt("Enter a number:", validate => { 'a number' => sub { /^\d+$/; }}, default => 1);
output("You selected: $v");
