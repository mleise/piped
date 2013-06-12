module sequencer.algorithm.copy;

import core.stdc.string : memcpy;
import core.thread;
import std.algorithm    : min;
import std.stdio;

import defs;
import sequencer.circularbuffer;
import sequencer.threads;


CCopyThread copy(T)(T source, ℕ maxBlockSize = 4.KiB)
{
	auto copyThread = new CCopyThread(source.toSequencerThread(), maxBlockSize);
	copyThread.start();
	return copyThread;
}

private final class CCopyThread : CAlgorithmThread
{
private:
	ℕ m_maxBlockSize;

	this(CSequencerThread thread, ℕ maxBlockSize)
	{
		super(thread);
		m_maxBlockSize = maxBlockSize;
	}

protected:
	override void run()
	{
		auto get = m_supplier.source;
		auto put = m_buffer.put;
		try while(true) {
			// we need at least 1 byte to start copying
			auto src = get.mapAtLeast(1);
			// and limit it somewhat, so we don't force unneccesarily large buffers
			immutable toCopy = min(src.length, m_maxBlockSize);
			// now copy this block into the destination buffer and mark the bytes as processed
			auto dst = m_buffer.mapWritable(toCopy);
			memcpy(dst, src.ptr, toCopy);
			get.release(toCopy);
			put.release(toCopy);
		} catch (EndOfStreamException) {
			// this is the expected outcome; not a single byte was left to copy
		}
	}
}
