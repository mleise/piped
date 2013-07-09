#!/bin/sh
if [ ! -e "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa.gz" ]
then
	echo "Downloading sample file..."
	wget "ftp://ftp.ensembl.org/pub/release-67/fasta/homo_sapiens/dna/Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa.gz"
fi
if [ ! -e "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa" ]
then
	echo "Extracting sample file..."
	gzip -dc "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa.gz" > "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa"
fi

echo
echo "Compiling..."
gcc gc_DanielSpaangberg_Tbl.c -ogc_benchmark_c \
	-ffunction-sections -fdata-sections -Wl,--gc-sections -O3 -march=native -pipe
#gdc gc_count.d ../../src/util.d ../../src/piped/circularbuffer.d ../../src/piped/threads.d ../../src/sys/memarch.d ../../src/piped/generic/consume.d ../../src/piped/text/lines.d ../../src/piped/compress/gzip.d ../../src/piped/source/file.d -I../../src -fversion=gc_benchmark -ogc_benchmark_d -frelease -fno-assert -fno-bounds-check \
#	-ffunction-sections -fdata-sections -Wl,--gc-sections -O3 -march=native -pipe
ldc2 gc_count.d ../../src/util.d ../../src/piped/circularbuffer.d ../../src/piped/threads.d ../../src/sys/memarch.d ../../src/piped/generic/consume.d ../../src/piped/text/lines.d ../../src/piped/compress/gzip.d ../../src/piped/source/file.d -I../../src -d-version=gc_benchmark -of=gc_benchmark_d -release \
	-ffunction-sections -fdata-sections -L=--gc-sections -O3

echo
echo "Benchmarking C..."
time ./gc_benchmark_c

echo
echo "Benchmarking D..."
time ./gc_benchmark_d
