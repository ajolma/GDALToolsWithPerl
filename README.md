# GDALToolsWithPerl
Small utility programs for geospatial data

Taking advantage of Geo::GDAL, PDL, etc.

histogram.pl filename step min numbins

Compute the histogram of a raster dataset. Output will be something like:

```
[abs_min .. min]: n1 values
(min .. x]: n2 values
..
(y .. abs_max]: nn values
m nodata values
```