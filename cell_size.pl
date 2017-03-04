#!/usr/bin/env perl

# Description for QGIS Perl Processing Provider Plugin:
# QP4: Name: Cell size (of a raster)
# QP4: Group: Raster tools
# QP4: Input: Raster,Raster,Raster
# QP4: Output: Number,CellSize,Cell size

# todo: options to control that we can require square cells 

use Modern::Perl;
use Geo::GDAL qw/:all/;

my ($r);
my $log_to;
for my $arg (@ARGV) {
    if ($arg =~ /^-([a-z])$/) {
        $log_to = 'stdout' if $1 eq 'l';
        next;
    }
    for ($r) {
        $_ = $arg, last unless defined $_;
    }
}
die "usage: perl cell_size.pl raster" unless $r;

my $t = Open(Name => $r, Type => 'Raster')->GeoTransform;

die "Not rectangular cells." if $t->[2] != 0 && $t->[4] != 0;
die "Not square cells." if abs($t->[1]) != abs($t->[5]);
say abs($t->[1]);
