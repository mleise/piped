module sequencer.algorithm.copy;

import core.stdc.string : memcpy;
import std.algorithm    : min;

import defs;
import sequencer.circularbuffer;
import sequencer.threads;


CCopyThread copy(T)(T source, in ℕ maxBlockSize = 4.KiB)
{
	return new CCopyThread(source.toSequencerThread(), maxBlockSize);
}

private final class CCopyThread : CAlgorithmThread
{
private:
	ℕ maxBlockSize;

	this(CSequencerThread thread, in ℕ maxBlockSize)
	{
		super(thread);
		this.maxBlockSize = maxBlockSize;
	}

protected:
	override void run()
	{
		auto get = this.supplier.source;
		auto put = this.buffer.put;
		try while(true) {
			// we need at least 1 byte to start copying
			auto src = get.mapAtLeast(1);
			// and limit it somewhat, so we don't force unneccesarily large buffers
			immutable toCopy = min(src.length, this.maxBlockSize);
			// now copy this block into the destination buffer and mark the bytes as processed
			auto dst = put.map(toCopy);
			memcpy(dst.ptr, src.ptr, toCopy);
			get.commit(toCopy);
			put.commit(toCopy);
		} catch (ConsumerStarvedException) {
			// this is the expected outcome; not a single byte was left to copy
		}
	}
}
