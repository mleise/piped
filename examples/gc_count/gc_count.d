module gc_count;

import core.time;
import std.stdio;

import util;
import piped.comp.gzip;
import piped.text.lines;


int main(string[] args)
{
	version (gc_benchmark) {
		string plain = "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa";
	} else version (profile) {
		string plain = "Homo_sapiens.GRCh37.67.dna_rm.chromosome.Y.fa";
	} else {
		if (args.length < 2) {
			stderr.writeln("You need to specify a FASTA file (which has a .gz version as well).");
			return 1;
		}
		string plain = args[1];
	}
	string gz = plain ~ ".gz";

	TickDuration t1, Δt;
	real gcFraction;
	
	// some tests...
	version (gc_benchmark) {
		gcFraction = countBasesThreaded(plain);
		writefln("%.3f %% G and C bases", gcFraction);
	} else {
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
	}
	return 0;
}



private:

real countBasesThreaded(string fname)
{
	auto lines = File(fname).splitLines(KeepTerminator.no);
	return countBasesImpl(lines);
}

real countBasesGZip(string fname)
{
	foreach (fname, inflator; File(fname).gzip()) {
		auto lines = inflator.splitLines(KeepTerminator.no);
		return countBasesImpl(lines);
	}
	return 0;
}

real countBasesPhobos(string fname)
{
	auto lines = File(fname).byLine();
	return countBasesImpl(lines);
}

real countBasesImpl(R)(ref R range)
{
	ℕ atCount, gcCount;
	foreach (line; range) {
		if (line.length != 0 && line[0] != '>' && line[0] != ';') {
			foreach (ch; line) {
				atCount += countAT[ch];
				gcCount += countGC[ch];
			}
		}
	}
	return (gcCount == 0) ? 0.0 : 100.0 * gcCount / (atCount + gcCount);
}

immutable ubyte[256] countAT;
immutable ubyte[256] countGC;

static this()
{
	countAT['A'] = 1;
	countAT['a'] = 1;
	countAT['T'] = 1;
	countAT['t'] = 1;
	countGC['G'] = 1;
	countGC['g'] = 1;
	countGC['C'] = 1;
	countGC['c'] = 1;
}
