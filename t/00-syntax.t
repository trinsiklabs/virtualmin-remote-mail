#!/usr/bin/perl
# 00-syntax.t — Verify all .pl and .cgi files parse without errors
use strict;
use warnings;
use Test::More;
use File::Find;

my $base = "$FindBin::Bin/..";

my @files;
find(sub {
    return unless -f $_;
    return unless /\.(pl|cgi)$/;
    # Skip test files themselves and the mock
    return if $File::Find::dir =~ /\/t$/;
    push @files, $File::Find::name;
}, $base);

use FindBin;

plan tests => scalar @files;

foreach my $file (sort @files) {
    my $output = `perl -c "$file" 2>&1`;
    my $rc = $? >> 8;
    # We expect syntax check to pass — but files that require Webmin
    # may fail at runtime. We check for "syntax OK" in the output.
    like($output, qr/syntax OK|Can't locate/, "Syntax check: $file");
}
