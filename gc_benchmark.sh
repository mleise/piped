#!/bin/sh
echo Compiling...
gcc gc_DanielSpaangberg_Tbl.c -ogc_benchmark_c -ffunction-sections -fdata-sections -Wl,--gc-sections -O3 -march=native -pipe
gdc src/defs.d src/fasta.d src/sequencer/circularbuffer.d src/sequencer/threads.d src/sys/memarch.d src/sequencer/algorithm/consume.d src/sequencer/algorithm/text.d src/sequencer/algorithm/gzip.d -fversion=gc_benchmark -ogc_benchmark_d -ffunction-sections -fdata-sections -Wl,--gc-sections -frelease -fno-assert -O3 -march=native -pipe -Isrc
echo
echo Benchmarking C...
time ./gc_benchmark_c
echo
echo Benchmarking D...
time ./gc_benchmark_d
