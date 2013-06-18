module piped.threads;

import core.exception;
import core.thread;
import std.stdio;

import util;
import piped.circularbuffer;
import piped.generic.consume;
import piped.source.file;


abstract class CSequencerThread : Thread
{
private:
	ℕ users = 0;

	debug(threads) ~this()
	{
		if (this.users) writeln("Thread user count was not 0 on destruction!");
	}

protected:
	SCircularBuffer buffer;

	this(string name)
	{
		super(&starter);
		this.name = name;
		this.buffer = SCircularBuffer(0);
	}

	void starter()
	{
		try {
			debug(threads) stderr.writefln("starting %s", name);
			this.run();
		} catch (ProducerStarvedException) {
			// Most of the time the producing thread can just stop running as well when the consumer quits.
			debug(threads) stderr.writeln(name ~ " caught a ProducerStarvedException.");
		} finally {
			this.buffer.put.finish();
			debug(threads) stderr.writefln("stopping %s", name);
		}
	}

	/// Implements the logic of this thread.
	abstract void run();

public:
	final @property SBufferPtr* source() pure nothrow
	{
		return this.buffer.get;
	}

	/**
	 * Increments the usage count of this thread. The first user also starts the thread.
	 * It is a logical error to have a CSequencerThread created but never call addUser().
	 */
	final void addUser()
	in { assert(this.users || !this.isRunning, "start() was called directly. Use addUser()"); }
	body {
		this.users++;
		if (this.users == 1) this.start();
	}

	/**
	 * Decrements the usage count of this thread. When the last user is removed, the thread
	 * is joined with that of the caller.
	 */
	final void removeUser()
	in { assert(this.users, "removeUser() called without starting the thread first"); }
	body {
		// When no algorithm makes use of us any more, we can abort.
		if (this.users == 1) {
			debug(threads) stderr.writefln("aborting %s", name);
			abort(this);
		}
		this.users--;
		if (this.users == 0) this.join();
	}
}

class CAlgorithmThread : CSequencerThread
{
protected:
	CSequencerThread supplier;

	override void starter()
	{
		this.supplier.addUser();
		try {
			super.starter();
		} finally {
			this.supplier.removeUser();
		}
	}

	this(CSequencerThread supplier)
	{
		super(this.classinfo.name ~ " (using: " ~ supplier.name ~ ")");
		this.supplier = supplier;
	}
}

CSequencerThread toSequencerThread(T)(T source)
{
	static if (is(T : CSequencerThread)) {
		return source;
	} else static if (is(T == File)) {
		return new CFileThread(source);
	} else static assert(format("Cannot create sequencer thread from a source of type %s.", T.stringof));
}