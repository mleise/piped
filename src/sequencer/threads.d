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
		m_buffer = SCircularBuffer(0);
	}

	~this()
	{
		debug(threads) stderr.writefln("%s destroyed", name);
	}
	
protected:
	SCircularBuffer m_buffer;

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
			m_buffer.finish();
			debug(threads) stderr.writefln("%s exiting", name);
		}
	}

	abstract void run();

public:
	final @property SBufferPtr* source() { return m_buffer.get; }
}

class CFileThread : CSequencerThread
{
private:
	File m_file;

	this(File file)
	{
		m_file = file;
	}

protected:
	override void run()
	{
		auto put = m_buffer.put;
		while (!m_file.eof) {
			auto mapped = put.map(64.KiB);
			auto read = m_file.rawRead(mapped[0 .. 64.KiB]);
			put.release(read.length);
		}
	}
}

class CAlgorithmThread : CSequencerThread
{
protected:
	CSequencerThread m_supplier;
	bool m_autoJoin = true;

	this(CSequencerThread supplier)
	{
		m_supplier = supplier;
	}

	override void starter()
	{
		// TODO: handle both cases: supplier threw exception, we threw exception
		if (m_autoJoin) scope(exit) {
			debug(threads) stderr.writefln("%s joining %s", name, m_supplier.name);
			m_supplier.join();
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