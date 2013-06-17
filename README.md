sequencer
=========

Creates one thread per algorithm and chains them together. Currently supports reading by line from gzip compressed FASTA files. The initial idea for parsing FASTA files came from this blog post:

[Calculating GC content in python and D - How to get 10x speedup in D](http://saml.rilspace.org/calculating-gc-content-in-python-and-d-how-to-get-10x-speedup-in-d)

Included versions of "calculate GC content" programs:
* [gc_test.py](gc_test.py) - the original Python version from Samuel Lampa.
* [gc_python.py](gc_python.py) - Samuel Lampa's version with improvents from Thomas Koch and lelledumbo.
* [gc_test_maximum.py](gc_test_maximum.py) - the fastest Python version from the comments section by cybervadim
* [gc_DanielSpaangberg_Tbl.c](gc_DanielSpaangberg_Tbl.c) - the fastest line reading C implementation by Daniel Spångberg

A script ([gc_benchmark.sh](gc_benchmark.sh)) can be used to compare the C version with the D version.

**An installation of GDC based on GCC 4.8.0 and D 2.062 is required.**
