module sequencer.threads;

import core.exception;
import core.thread;
import std.stdio;

import defs;
import sequencer.circularbuffer;


abstract class CSequencerThread : Thread
{
	// TODO: provide static factory methods to return constructed and started threads ? Otherwise calling start can be forgotten.
private:
	this()
	{
		super(&starter);
		name = this.classinfo.name;
		this.buffer = SCircularBuffer(0);
	}

	pure nothrow ~this()
	{
		debug(threads) stderr.writefln("%s destroyed", name);
	}
	
protected:
	SCircularBuffer buffer;

	void starter()
	{
		try {
			debug(threads) stderr.writefln("%s starting", name);
			run();
		} catch (AssertError e) {
			// In D we shouldn't try to catch asserts, but otherwise only asserts in the
			// main thread get printed to stderr.
			stderr.writeln(e);
			stderr.writeln(e.info);
		} finally {
			this.buffer.finish();
			debug(threads) stderr.writefln("%s exiting", name);
		}
	}

	abstract void run();

public:
	final @property SBufferPtr* source() pure nothrow
	{
		return this.buffer.get;
	}
}

class CFileThread : CSequencerThread
{
private:
	File file;

	this(File file)
	{
		this.file = file;
	}

protected:
	override void run()
	{
		auto put = this.buffer.put;
		while (!this.file.eof) {
			auto mapped = put.map(64.KiB);
			auto read = this.file.rawRead(mapped[0 .. 64.KiB]);
			put.commit(read.length);
		}
	}
}

class CAlgorithmThread : CSequencerThread
{
protected:
	CSequencerThread supplier;
	bool autoJoin = true;

	this(CSequencerThread supplier)
	{
		this.supplier = supplier;
	}

	override void starter()
	{
		// TODO: handle both cases: supplier threw exception, we threw exception
		if (this.autoJoin) scope(exit) {
			debug(threads) stderr.writefln("%s joining %s", name, this.supplier.name);
			this.supplier.join();
		}
		super.starter();
	}
}

CSequencerThread toSequencerThread(T)(T source)
{
	static if (is(T : CSequencerThread)) {
		return source;
	} else static if (is(T == File)) {
		auto fileThread = new CFileThread(source);
		fileThread.start();
		return fileThread;
	} else static assert(format("Cannot create sequencer thread from a source of type %s.", T.stringof));
}