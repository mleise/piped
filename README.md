sequencer
=========

Creates one thread per algorithm and chains them together. Currently supports reading by line from gzip compressed FASTA files.

The initial idea for parsing FASTA files came from this blog post: http://saml.rilspace.org/calculating-gc-content-in-python-and-d-how-to-get-10x-speedup-in-d

I have included the original Python version and a highly optimized one that reads the whole file at once.

Compile with:
```
ldc2 -release -O3 src/defs.d src/fasta.d src/sequencer/circularbuffer.d src/sequencer/threads.d src/sys/memarch.d src/sequencer/algorithm/text.d src/sequencer/algorithm/copy.d src/sequencer/algorithm/gzip.d -of=bin/Release/FASTA -od=bin/Release -vectorize -vectorize-loops -unit-at-a-time
```
