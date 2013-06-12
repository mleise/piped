sequencer
=========

Creates one thread per algorithm and chains them together. Currently supports reading by line from gzip compressed FASTA files.
The initial idea for parsing FASTA files came from this blog post: http://saml.rilspace.org/calculating-gc-content-in-python-and-d-how-to-get-10x-speedup-in-d
I have included the original Python version and a highly optimized one that reads the whole file at once.
