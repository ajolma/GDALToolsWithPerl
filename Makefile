PREFIX=~/usr

install:
	cp histogram.pl $(PREFIX)/bin
	chmod +x $(PREFIX)/bin/histogram.pl
	cp dijkstra.pl $(PREFIX)/bin
	chmod +x $(PREFIX)/bin/dijkstra.pl
