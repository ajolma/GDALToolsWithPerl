#!/usr/bin/env perl

use Modern::Perl;
use Geo::GDAL;
use Hash::PriorityQueue;
use Term::ProgressBar;

my ($dest, $space, $output, $cell_size);
my $use_log;
for my $arg (@ARGV) {
    if ($arg =~ /^-([a-z])$/) {
        $use_log = 1 if $1 eq 'l';
        next;
    }
    for ($dest, $space, $output, $cell_size) {
        $_ = $arg, last unless defined $_;
    }
}
die "usage: perl dijkstra.pl dest space output cell_size" unless defined $cell_size;
die "will not overwrite $output" if -e $output;

$|++ if $use_log;

my ($w, $h, $costs, $unvisited, $count, $current) = prepare($dest, $space);

dijkstra($costs, $unvisited, $count, $current);

create_cost_to_go($costs, $w, $h, $space, $output);

sub create_cost_to_go {
    my ($costs, $W, $H, $space, $output) = @_;

    my $ds = Geo::GDAL::Open($space);

    my $out = Geo::GDAL::Driver('GTiff')->Create(
        Name => $output, 
        Width => $w, 
        Height => $h, 
        Bands => 1,
        Type => 'Float32'
        )->Band;

    $out->Dataset->GeoTransform($ds->GeoTransform);
    $out->Dataset->SpatialReference($ds->SpatialReference);

    say "Create output:";
    my $progress = $use_log ? 0 : Term::ProgressBar->new({count => $H});
    my $size = 1;
    my($xoff,$yoff,$w,$h) = (0,0,255,255);
    while (1) {
        if ($xoff >= $W) {
            $xoff = 0;
            $yoff += $h;
            if ($use_log) {
                say "$yoff/$H";
            } else {
                $progress->update(smaller($yoff,$H));
            }
            last if $yoff >= $H;
        }
        my $w_real = smaller($W-$xoff,$w);
        my $h_real = smaller($H-$yoff,$h);
        
        my $tile = [];
        
        for my $y (0..$h_real-1) {
            for my $x (0..$w_real-1) {

                my $xr = $xoff+$x;
                my $yr = $yoff+$y;

                if ($costs->{$xr}{$yr}) {
                    $tile->[$y][$x] = $costs->{$xr}{$yr};
                } else {
                    $tile->[$y][$x] = 0;
                }   
                
            }
        }

        $out->WriteTile($tile, $xoff, $yoff);
        
        $xoff += $w;
    }

}

sub dijkstra {
    my ($costs, $unvisited, $count, $current) = @_;

    say "Compute cost-to-gos:";
    my $progress = $use_log ? 0 : Term::ProgressBar->new({count => $count});
    my @current = @$current;
    my $d = 0;

    #my %costs;

# dijkstra:
# 1. set current to (one of the) unvisited locs with smallest cost-to-go
# 2. examine its unvisited nborhood and set their cost-to-go
# 3. remove current from unvisited
# 4. stop if no more unvisited
# 5. go to 1.

    my $my_count = 0;
    while (1) {
        $costs->{$current[0]}{$current[1]} = $d;
        $my_count++;
        if ($use_log) {
            say "$my_count/$count" if $my_count % 100 == 0;
        } else {
            $progress->update($my_count);
        }
        for my $x ($current[0]-1..$current[0]+1) {
            for my $y ($current[1]-1..$current[1]+1) {
                my $u = $costs->{$x}{$y};
                next unless defined $u;
                next unless $u == -1;
                
                my $t; # distance
                if ($x == $current[0]) {
                    next if $y == $current[1];
                    $t = $cell_size;
                }
                if ($y == $current[1]) {
                    $t = $cell_size;
                }
                $t = sqrt(2)*$cell_size unless $t;
                $t += $d;
                
                my $key = "$x,$y";
                # need $unvisited->priority($payload)
                my $v = $unvisited->{prios}->{$key};
                if (!defined($v) or $t < $v) {
                    $unvisited->update($key, $t);
                }
            }
        }
        $unvisited->delete("$current[0],$current[1]");    
        last unless defined $unvisited->{min_key};
        
        # need $unvisited->lowest_priority
        $d = $unvisited->{prios}->{$unvisited->{queue}->{$unvisited->{min_key}}->[0]};
        @current = split /,/, $unvisited->pop;
        
        
    }
    say STDERR "Computed cost for $my_count cells from $count prepared." if $my_count != $count;
}

sub prepare {
    my ($dest_d, $space_d) = @_;

    my $dest_b = Geo::GDAL::Open($dest_d)->Band;
    my $space_b = Geo::GDAL::Open($space_d)->Band;
    my ($W, $H) = $space_b->Size;
    my @s = $dest_b->Size;
    die "size don't match" if $W != $s[0] || $H != $s[1];

    my %costs;
    my $unvisited = Hash::PriorityQueue->new;
    my $count = 0;
    
    my @current;
    
    say "Prepare input data:";
    my $progress = $use_log ? 0 : Term::ProgressBar->new({count => $H});
    my $size = 1;
    my($xoff,$yoff,$w,$h) = (0,0,255,255);
    while (1) {
        if ($xoff >= $W) {
            $xoff = 0;
            $yoff += $h;
            if ($use_log) {
                say "$yoff/$H";
            } else {
                $progress->update(smaller($yoff,$H));
            }
            last if $yoff >= $H;
        }
        my $w_real = smaller($W-$xoff,$w);
        my $h_real = smaller($H-$yoff,$h);
        
        my $dest = $dest_b->ReadTile($xoff, $yoff, $w_real, $h_real);
        my $space = $space_b->ReadTile($xoff, $yoff, $w_real, $h_real);
        
        for my $y (0..$h_real-1) {
            for my $x (0..$w_real-1) {

                next unless $space->[$y][$x];

                my $xr = $xoff+$x;
                my $yr = $yoff+$y;
                
                if ($dest->[$y][$x]) {
                    $unvisited->insert("$xr,$yr", 0);
                    @current = ($xr,$yr) unless @current;
                    $count++;
                } else {
                    $costs{$xr}{$yr} = -1;
                    $count++;
                }   
                
            }
        }
        
        $xoff += $w;
    }

    return ($W, $H, \%costs, $unvisited, $count, \@current);
}

sub smaller {
    return $_[0] < $_[1] ? $_[0] : $_[1];
}
