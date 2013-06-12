module fasta;

import core.time;
import std.stdio;

import defs;
import sequencer.algorithm.gzip;
import sequencer.algorithm.text;


int main(string[] args)
{
	if (args.length < 3) {
		stderr.writeln("You need to specify a FASTA file and its gzip comressed version.");
		return 1;
	}
	version(profile) {
		string plain = "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa";
		string gz    = "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa.gz";
	} else {
		string plain = args[1];
		string gz    = args[2];
	}

	TickDuration t1, Δt;
	real gcFraction;
	
	// some tests...
	writeln("Counting bases using different line reading approaches...");
	t1 = TickDuration.currSystemTick;
	gcFraction = countBasesThreaded(plain);
	Δt = TickDuration.currSystemTick - t1;
	writefln("threaded buffer system          in %4s ms: %.2f%% G and C bases", Δt.msecs, gcFraction);

	// TODO: make this not hang on non-gzip file
	t1 = TickDuration.currSystemTick;
	gcFraction = countBasesGZip(gz);
	Δt = TickDuration.currSystemTick - t1;
	writefln("threaded buffer system, gzipped in %4s ms: %.2f%% G and C bases", Δt.msecs, gcFraction);

	t1 = TickDuration.currSystemTick;
	gcFraction = countBasesPhobos(plain);
	Δt = TickDuration.currSystemTick - t1;
	writefln("File.byLine                     in %4s ms: %.2f%% G and C bases", Δt.msecs, gcFraction);
	return 0;
}



private:

real countBasesPhobos(string fname)
{
	return File(fname).byLine().countBasesImpl();
}

real countBasesGZip(string fname)
{
	foreach (fname, inflator; File(fname).gzip()) {
		auto lines = inflator.splitLines(KeepTerminator.no);
		// TODO: Do I properly handle early breaks here?
		return countBasesImpl(lines);
	}
	return 0;
}

real countBasesThreaded(string fname)
{
	return File(fname).splitLines(KeepTerminator.no).countBasesImpl();
}

real countBasesImpl(R)(R range)
{
	ℕ totalBaseCount, gcCount;
	foreach (line; range) {
		if (line.length == 0 || line[0] == '>' || line[0] == ';')
			continue;
		foreach (ch; line) {
			if (ch == 'C' || ch == 'T' || ch == 'G' || ch == 'A') {
				totalBaseCount++;
				if (ch == 'G' || ch == 'C') {
					gcCount++;
				}
			}   
		}
	}
	return 100.0 * gcCount / totalBaseCount;
}