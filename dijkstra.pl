#!/usr/bin/env perl

# Description for QGIS Perl Processing Provider Plugin:
# QP4: Name: Distance to destination (in raster)
# QP4: Group: Optimization
# QP4: Input: Raster,Destinations,Destinations
# QP4: Input: Raster,Space,Space
# QP4: Output: Raster,Distances,Distances to destinations using space
# QP4: Input: Extent,Extent,Extent (if not set the intersection of Destinations and Space is used)

use Modern::Perl;
use Geo::GDAL qw/:all/;
use Hash::PriorityQueue;

my ($dest, $space, $output, $extent);
my $quiet;
my $log_to;
my $overwrite;
for my $arg (@ARGV) {
    if ($arg =~ /^-([a-z])$/) {
        $quiet = 1 if $1 eq 'q';
        $log_to = 'stdout' if $1 eq 'l';
        $overwrite = 1 if $1 eq 'o';
        next;
    }
    for ($dest, $space, $output, $extent) {
        $_ = $arg, last unless defined $_;
    }
}
die "usage: perl dijkstra.pl dest space output [extent]" unless $output;
die "will not overwrite $output" if -e $output && !$overwrite;

$dest = {dataset => Open(Name => $dest, Type => 'Raster')};
$space = {dataset => Open(Name => $space, Type => 'Raster')};

# todo: check north-up

# shrink extent to be completely inside of both input rasters
# thus private xoff and yoff of both are non-negative
if ($extent) {
    $extent =~ s/^"//;
    $extent =~ s/"$//;
    my @e = split(/,/, $extent);
    die "The extent must be xmin,ymin,xmax,ymax" unless @e == 4;
    $extent = Geo::GDAL::Extent->new(@e);
    $extent = $dest->{dataset}->Extent->Overlap($extent) if $extent;
    $extent = $space->{dataset}->Extent->Overlap($extent) if $extent;
} else {
    $extent = $space->{dataset}->Extent->Overlap($dest->{dataset}->Extent);
}
die "There is no overlap." unless $extent;

my $cell_size;
{
    my @cell_sizes;
    for ($dest, $space) {
        $_->{band} = $_->{dataset}->Band;
        my @size = $_->{dataset}->Size;
        $_->{size} = \@size;
        my $e = $_->{dataset}->Extent;
        my $dw = ($e->[2]-$e->[0])/$size[0];
        my $dh = ($e->[3]-$e->[1])/$size[1];
        $_->{xoff} = int(($extent->[0] - $e->[0]) / $dw + 0.5);
        $_->{yoff} = int(($e->[3] - $extent->[3]) / $dh + 0.5); # assuming ymax is at row 0
        push @cell_sizes, $dw;
        push @cell_sizes, $dh;
    }
    my @sizes = @cell_sizes;
    $cell_size = shift @cell_sizes;
    for my $size (@cell_sizes) {
        die "Cells are not rectangular or not of same size in input rasters" 
            unless $cell_size-$size < 0.001;
    }
}

my @size = (
    POSIX::ceil(($extent->[2]-$extent->[0])/$cell_size), 
    POSIX::ceil(($extent->[3]-$extent->[1])/$cell_size)
    );

$output = Geo::GDAL::Driver('GTiff')->Create(
    Name => $output, 
    Width => $size[0],
    Height => $size[1],
    Bands => 1,
    Type => 'Float32'
    );
$output->GeoTransform(Geo::GDAL::GeoTransform->new($extent->[0], $cell_size, 0, $extent->[3], 0, -$cell_size));
$output->SpatialReference($dest->{dataset}->SpatialReference);

$|++ if $log_to;

my ($costs, $unvisited, $count, $current) = prepare();

dijkstra($costs, $unvisited, $count, $current);

create_cost_to_go();

{
    package Progress;
    use Modern::Perl;
    use Term::ProgressBar;
    sub new {
        my ($class, $self) = @_;
        if ($self->{quiet}) {
        } elsif ($self->{log_to}) {
            $self->{counter} = 0;
        } else {
            return Term::ProgressBar->new({count => $self->{count}});
        }
        bless $self, $class;
    }
    sub update {
        my ($self, $value) = @_;
        return if $self->{quiet};
        if ($self->{log_to}) {
            my $c = int($value/$self->{count}*100);
            if ($c > $self->{counter}) {
                if ($self->{log_to} eq 'stdout') {
                    say "$c/100";
                } else {
                    say STDERR "$c/100";
                }
                $self->{counter} = $c;
            }
        }
    }
}

sub create_cost_to_go {
    say "Create output:" unless $quiet;
    $output = $output->Band;
    my $progress = Progress->new({quiet => $quiet, count => $size[1], log_to => $log_to});
    my($xoff,$yoff,$w,$h) = (0,0,256,256);
    while (1) {
        if ($xoff >= $size[0]) {
            $xoff = 0;
            $yoff += $h;
            $progress->update(smaller($yoff,$size[1]));
            last if $yoff >= $size[1];
        }
        my $w_real = smaller($size[0]-$xoff,$w);
        my $h_real = smaller($size[1]-$yoff,$h);
        
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

        $output->WriteTile($tile, $xoff, $yoff);
        
        $xoff += $w;
    }

}

sub dijkstra {
    my ($costs, $unvisited, $count, $current) = @_;

    say "Compute cost-to-gos:" unless $quiet;
    my $progress = Progress->new({quiet => $quiet, count => $count, log_to => $log_to});
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
        $progress->update($my_count);
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

    my %costs;
    my $unvisited = Hash::PriorityQueue->new;
    my $count = 0;
    
    my @current;
    
    say "Prepare input data:" unless $quiet;
    my $progress = Progress->new({quiet => $quiet, count => $size[1], log_to => $log_to});
    my $size = 1;
    my($xoff,$yoff,$w,$h) = (0,0,256,256);
    while (1) {
               
        if ($xoff >= $size[0]) {
            $xoff = 0;
            $yoff += $h;
            $progress->update(smaller($yoff,$size[1]));
            last if $yoff >= $size[1];
        }

        my $d = read_from_band($dest, $xoff, $yoff, $w, $h);
        my $s = read_from_band($space, $xoff, $yoff, $w, $h);
        
        for my $y (0..$h-1) {
            for my $x (0..$w-1) {

                next unless $s->[$y][$x];

                my $xr = $xoff+$x;
                my $yr = $yoff+$y;
                
                if ($d->[$y][$x]) {
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

    return (\%costs, $unvisited, $count, \@current);
}

sub read_from_band {
    my ($band, $xoff, $yoff, $w, $h) = @_;
    $xoff = $band->{xoff}+$xoff;
    $yoff = $band->{yoff}+$yoff;
    $w = smaller($band->{size}[0]-$xoff,$w);
    $h = smaller($band->{size}[1]-$yoff,$h);
    return $band->{band}->ReadTile($xoff, $yoff, $w, $h);
}

sub smaller {
    return $_[0] < $_[1] ? $_[0] : $_[1];
}
