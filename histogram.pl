#!/usr/bin/env perl

use Modern::Perl;
use Term::ProgressBar;
use Geo::GDAL;
use PDL;
use PDL::NiceSlice;

my ($filename, $step, $min, $numbins);
my $quiet;
for my $arg (@ARGV) {
    if ($arg =~ /^-([a-z])/) {
        $quiet = 1 if $1 eq 'q';
        next;
    }
    for ($filename, $step, $min, $numbins) {
        $_ = $arg, last unless defined $_;
    }
}
die "usage: perl histogram.pl [-q] filename [step] [min] [numbins]" unless defined $filename;
my $only_filename = !defined($step);
$step //= 1;
$min //= 0;
$numbins //= 1;
die "numbins must be greater than zero " unless $numbins > 0;
my $band = Geo::GDAL::Open(Name => $filename, Access => 'ReadOnly')->Band();
my ($w_band, $h_band) = $band->Size;
my $nodata = $band->NoDataValue;
my $dt = $band->DataType;
unless ($quiet) {
    say "The data type of the raster is $dt.";
    if (defined $nodata) {
        say "The NoData value is $nodata.";
    } else {
        say "The NoData value is not defined.";
    }
}

if ($Geo::GDAL::VERSION >= 2.02 and ($dt eq 'Byte' or $dt =~ /^U*Int/) and $only_filename) {
    my $bar = $quiet ? 0 : Term::ProgressBar->new({count => 1});
    my $counts = $band->ClassCounts(
        sub 
        {
            my ($progress) = @_;
            $bar->update($progress) unless $quiet;
            return 1;
        }
        );
    my $sum = 0;
    for my $class (sort {$a<=>$b} keys %$counts) {
        my $nd = '';
        $nd = " (NoData)" if defined $nodata && $class == $nodata;
        say "$class $counts->{$class}$nd";
        $sum += $counts->{$class};
    }
    say STDERR "Whoa! something is wrong got $sum values out of ",$w_band*$h_band
        if $sum != $w_band*$h_band;
    exit;
}

my $progress = $quiet ? 0 : Term::ProgressBar->new({count => $h_band});
my ($w_block, $h_block) = $band->GetBlockSize;
my ($xoff, $yoff) = (0,0);
my $hist;
my $bad;
my $abs_min;
my $abs_max;
while (1) {
    if ($xoff >= $w_band) {
        $xoff = 0;
        $yoff += $h_block;
        $progress->update(smaller($yoff, $h_band)) unless $quiet;
        last if $yoff >= $h_band;
    }
    my $piddle = $band->Piddle(
        $xoff, 
        $yoff, 
        smaller($w_band-$xoff, $w_block), 
        smaller($h_band-$yoff, $h_block));

    my @stats = stats($piddle); # 3 and 4 are min and max
    my $has_stats = not isbad($stats[3]);

    if ($has_stats) {
        if (defined $abs_min) {
            $abs_min = smaller($abs_min, $stats[3]);
            $abs_max = greater($abs_max, $stats[4]);
        } else {
            $abs_min = $stats[3];
            $abs_max = $stats[4];
        }
    }
    
    #for docs see http://pdl.perl.org/PDLdocs/Primitive.html#histogram
    my $h = histogram($piddle, $step, $min, $numbins);
    my $nbad = nbad($piddle);

    # h has per row data, we need to sum the rows
    $h = sumover $h->xchg(0,1);

    unless (defined $hist) {
        $hist = $h;
        $bad = $nbad;
    } else {
        $hist += $h;
        $bad += $nbad;
    }

    $xoff += $w_block;
}

unless ($quiet) {
    if (defined $abs_min) {
        say "min value is $abs_min and max value is $abs_max";
    } else {
        say "There are only nodata values in the raster.";
    }
}

my @hist = $hist->list;

my $max = $min+$step;
$min = $abs_min;
my $lower_boundary = '[';
my $sum = 0;
for my $i (0..$#hist) {
    $sum += $hist[$i];
    $max = $abs_max if $i == $#hist && $abs_max > $max;
    say "$lower_boundary$min .. $max]: $hist[$i] values";
    $lower_boundary = '(';
    $min = $max;
    $max += $step;
}
say "NoData: $bad values" if defined $nodata;
$sum += $bad;
say STDERR "Whoa! something is wrong got $sum values out of ",$w_band*$h_band
    if $sum != $w_band*$h_band;

sub smaller {
    return $_[0] < $_[1] ? $_[0] : $_[1];
}

sub greater {
    return $_[0] > $_[1] ? $_[0] : $_[1];
}
