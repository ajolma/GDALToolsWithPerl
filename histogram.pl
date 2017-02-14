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
die "usage: perl histogram.pl filename step min numbins" unless defined $numbins;
die "numbins must be greater than zero " unless $numbins > 0;
my $access = 'ReadOnly';
my $update = $access eq 'Update';
my $band = Geo::GDAL::Open(Name => $filename, Access => $access)->Band();

my ($w_band, $h_band) = $band->Size;
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
    
    #for docs see http://pdl.perl.org/PDLdocs/Primitive.html#histogram
    my $h = histogram($piddle, $step, $min, $numbins);
    my $nbad = nbad($piddle);

    unless (defined $hist) {
        $hist = $h;
        $bad = $nbad;
        if ($has_stats) {
            $abs_min = $stats[3];
            $abs_max = $stats[4];
        }
    } else {
        $hist += $h;
        $bad += $nbad;
        if ($has_stats) {
            $abs_min = smaller($abs_min, $stats[3]);
            $abs_max = greater($abs_max, $stats[4]);
        }
    }

    $band->Piddle($a, $xoff, $yoff) if $update;
    $xoff += $w_block;
}
say "min value is $abs_min and max value is $abs_max";

my @dims = dims($hist);

# merge the two dimensions (if exist):
$hist = $hist(:,0)+$hist(:,1) if $dims[1] == 2;

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
say "$bad nodata values";
$sum += $bad;
say STDERR "Whoa! something is wrong got $sum values out of ",$w_band*$h_band
    if $sum != $w_band*$h_band;

sub smaller {
    return $_[0] < $_[1] ? $_[0] : $_[1];
}

sub greater {
    return $_[0] > $_[1] ? $_[0] : $_[1];
}
