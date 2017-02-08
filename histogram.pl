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
die "usage: perl gdal_histogram.pl filename step min numbins" unless defined $numbins;
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
            $abs_max = bigger($abs_max, $stats[4]);
        }
    }

    $band->Piddle($a, $xoff, $yoff) if $update;
    $xoff += $w_block;
}

# merge the two dimensions:
$hist = $hist(:,0)+$hist(:,1);
my @hist = $hist->list;

my $max = $min;
$min = $abs_min;
my $lower_boundary = '[';
for my $i (0..$#hist) {
    say "$lower_boundary$min .. $max]: $hist[$i] values";
    $lower_boundary = '(';
    $min = $max;
    if ($i == $#hist) {
        $max = $abs_max;
    } else {
        $max += $step;
    }
}
say "$bad nodata values";

sub smaller {
    return $_[0] < $_[1] ? $_[0] : $_[1];
}

sub bigger {
    return $_[0] > $_[1] ? $_[0] : $_[1];
}
