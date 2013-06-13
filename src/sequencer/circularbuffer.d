module sequencer.circularbuffer;

import core.atomic;
import core.stdc.stdlib;
import core.stdc.string;
import core.sync.condition;
import core.sync.mutex;
import core.sys.posix.stdlib;
import core.sys.posix.sys.mman;
import std.algorithm;
import std.stdio;
import std.traits;
import std.typecons;
import sys.memarch;
import defs;
import core.thread;
import core.sync.semaphore;
import std.string;
import std.conv;
import core.sys.posix.sys.mman;
import core.sys.posix.pthread;


class EndOfStreamException : Exception
{
    @safe pure nothrow this(string msg, string file = __FILE__, size_t line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, size_t line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

/**
 * Course of action for write requests:
 * 
 * if enough space is available for the write request:
 *   return
 * if read_requirement is set (meaning the consumer starves):
 *   ### asserts that the available buffer cannot grow any more by the consumer removing data
 *   if enough space is available for the write request:
 *     return
 * else:
 *   ### we have the consumer still running, so enough free space may become available
 *   ### if that's not happening, we need a buffer resize and have to wait for the consumer to halt
 *   write_requirement = current_request
 *   ### now we wait for the consumer to either consume enough or starve
 *   ### either way it signals us to take action
 *   wait for the writer continue signal from the consumer
 *   ### we could check write_requirement == 0 here, but what we really want to know is, whether both threads stopped
 *   ### for a moment, since that harms the throughput we seek to maximize
 *   if the consumer doesn't starve:
 *     return
 * grow buffer to optimal size for both threads
 * 
 * Course of action for read requests:
 * 
 * if there is not enough space available for the read request:
 *   ### the consumer starves
 *   read_requirement = current_request
 *   wait for the reader continue signal from the producer
 */
struct SCircularBuffer
{
private:
	// TODO: Is it better to flush uncommitted bytes before asking for more buffer ? It could move the flushing out of grow() but not buy us much.

	ubyte*        m_buf;   /// The pointer to the buffer start.
	SBufferPtr[2] m_bptr;
	ℕ             m_size;  /// published buffer size (excluding mirror pages)
	shared ℕ      m_fill;  /// amount unprocessed (unread) data available to the consumer
	Condition     m_cond;
	shared bool   m_eof;
	ℕ             m_heat;

	/**
	 * Fulfils the growth request on this buffer. Assumtion: Only one thread is active when entering.
	 * Twice the amount of virtual memory is allocated and the second half is then set up to mirror the first.
	 * This is a common technique to hide the wrap around at the end of the buffer that would otherwise occur.
	 * In fact I allocate 4 times the required memory to align the block so that all the "lower" bits of the start
	 * address are 0. Then the read and write pointers can easily be constrained to the available buffer by ANDing them
	 * with a mask. The superflous memory is then deallocated, so that the long-term VM usage is buffer size * 2.
	 * 
	 * HINT: I may need to restrict growing a bit. Currently whenever both threads starve I increase the buffer. But
	 * since the lock-free part together with thread scheduling can cause this situation even with sufficient buffer
	 * space, there is no upper bound to the growth.
	 */
	void grow(ℕ optimal)
	in {
		assert(optimal);
	} out {
//		assert(cast(ubyte*) (cast(ℕ) m_buf + m_size & m_mask) is m_buf);
	} body {
		debug(circularbuffer) stderr.writeln("producer initiates grow");
		if (m_bptr[0].m_buf !is &this)
			stderr.writeln("ARRRRR");
		immutable size = max(optimal, 2 * m_size, allocationGranularity).growToPowerOf2();
		// we must be able to split the virtual memory in half for our mirror pages...
		debug(circularbuffer) stderr.writefln("Growth request to %s KiB (%s)", size / 1024, Thread.getThis.name);
		auto bufOld = m_buf;
		m_buf = cast(ubyte*) mmap(null, 4 * size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);

		// cut out a piece that fits our bit masking requirement and deallocate the rest
		auto cut = m_buf.alignPtrToNextMultipleOfPowerOfTwoValue(2 * size);
		debug(circularbuffer) stderr.writefln("Cutting out: %s -> %s", m_buf, cut);
		immutable pgoff = cut - m_buf;
		munmap(m_buf, pgoff);
		munmap(cut + 2 * size, 2 * size - pgoff);
		m_buf = cut;

		// map second half as mirror of first
		if (remap_file_pages(m_buf + size, size, 0, pgoff / systemPageSize, 0)) {
			stderr.writeln("remap_file_pages failed");
		}

		// Copy memory
		foreach (ref b; m_buf[0 .. size]) {
			b = 'X';
		}
		if (m_buf[0 .. size] != m_buf[size .. 2*size]) {
			stderr.writeln("oh no");
		}
		if (m_size) foreach (i; 0 .. size / m_size) {
			m_buf[i * m_size .. (i+1) * m_size] = bufOld[0 .. m_size];
		}
		if (m_buf[0 .. 2 * m_size] != bufOld[0 .. 2 * m_size]) {
			stderr.writeln("oh no 2");
		}

		// The put pointer is always adjusted relative to the buffer start as it will write into the new space ahead.
		m_bptr[Access.put].m_ptr += m_buf - bufOld;
		// The get pointer 'follows' the put pointer.
		m_bptr[Access.get].m_ptr += m_buf - bufOld;
		m_fill -= m_bptr[Access.get].m_delayed;
		m_fill += m_bptr[Access.put].m_delayed;
		m_bptr[Access.get].m_delayed = 0;
		m_bptr[Access.put].m_delayed = 0;
		if (m_fill != 0 && m_bptr[Access.get].m_ptr >= m_bptr[Access.put].m_ptr) {
			m_bptr[Access.put].m_ptr += m_size;
		}

		// release old mapping
		if (bufOld) munmap(bufOld, 2 * m_size);

		// growth request is now satisfied
		immutable mask = cast(ℕ) m_buf & -size | (size - 1);
		m_bptr[0].m_mask = m_bptr[1].m_mask = mask;
		m_size = size;
	}

	void producerStarve(ℕ count)
	out {
		immutable available = availableReal(Access.put);
		assert(available >= count, format("makeWritable: failed to make %s bytes available for put access (only %s are available)", count, available));
	} body {
		m_bptr[Access.put].m_max.correctUpwards(count);
		m_cond.mutex.lock();
		scope(exit) m_cond.mutex.unlock();

		// Collect information on the state of affairs
		bool requestFulfilled = false;
		bool mutuallyBlocked = m_bptr[Access.get].m_req != 0;
		if (!mutuallyBlocked) {
			// no, so we have a chance of resolving this by waiting for the consumer to free some buffer space
			debug(circularbuffer) writefln("producer is out of buffer space and asks consumer for %s bytes", count);
			m_bptr[Access.put].m_req = count;
			// Now we wait for the consumer to either consume enough or starve. Either way it signals us to take action.
			debug(circularbuffer) writeln("producer enters wait");
			wrw++;
			do {
				m_cond.wait();
			} while (m_bptr[Access.put].m_req == count);
			debug(circularbuffer) writeln("producer exits wait");
			// HINT: At this point, the consumer isn't neccessarily starving!
			// It might have seen our request, fulfilled it and went on. Eventually it might then run out of buffer and
			// starve, but those are two distinct cases.
			mutuallyBlocked = m_bptr[Access.get].m_req != 0;
			requestFulfilled = availableReal(Access.put) >= count;
			if (!mutuallyBlocked && !requestFulfilled)
				stderr.writefln("logical error in makeWritable(): %s/%s", m_fill, m_size);
		} else {
//			writeln("producer sees consumer starving");
		}

		// Take action (not mutually blocked and yet not fulfilled should be impossible)
		if (mutuallyBlocked) {
			// We might want to grow the buffer, calculate a good buffer size
			if (m_heat < 100) m_heat += 10;
			immutable optimal = 2 * (delayable + m_bptr[Access.get].m_max + m_bptr[Access.put].m_max);
			if (optimal > m_size || (m_heat >= 100) && (m_size < 4 * optimal)) {
//			if (m_size == 0) {
				grow(optimal);
				m_bptr[Access.put].m_req = 0;
				m_heat = 0;
			}
			// HINT: The consumer might have starved, then locked the mutex while the producer was still filling the buffer
			//       In that case we send it back to work right away. In fact, the producer might run out of free space
			//       and dead-lock if we don't.
			if (m_bptr[Access.get].m_req <= availableReal(Access.get)) {
				m_bptr[Access.get].m_req = 0;
				wrn++;
				m_cond.notify();
				if (count > availableReal(Access.put)) {
					m_bptr[Access.put].m_req = count;
					debug(circularbuffer) writeln("producer enters wait");
					wrw++;
					do {
						m_cond.wait();
					} while (m_bptr[Access.put].m_req == count);
					debug(circularbuffer) writeln("producer exits wait");
				}
			}
		} else {
			// cool down thread collision counter
			if (m_heat) m_heat--;
			if (!requestFulfilled)
				// request must have been fulfilled by consumer
				throw new Exception("Error in makeWritable, request was expected to be fulfilled by consumer");
			if (count > availableReal(Access.put)) writefln("makeWritable: %s error, expected consumer to fulfill request", Access.put); 
			m_bptr[Access.put].m_req = 0;
		}
	}

	/// Called when we ran out of buffer for reading (excluding unflushed bytes from the producer).
	void consumerStarve(ℕ count)
	{
		m_bptr[Access.get].m_max.correctUpwards(count);
		m_cond.mutex.lock();
		scope(exit) m_cond.mutex.unlock();

		bool mutuallyBlocked = m_bptr[Access.put].m_req != 0;
		if (!mutuallyBlocked) {
			if (!m_eof) {
				m_bptr[Access.get].m_req = count;
				rdw++;
				do {
					m_cond.wait();
				} while (m_bptr[Access.get].m_req == count);
			}
			if (m_eof && count > availableReal(Access.get)) {
				m_bptr[Access.get].m_knownMappable = availableReal(Access.get);
				throw new EndOfStreamException(format("Not enough data to read %s bytes", count));
			}
		} else {
//			writeln("consumer -> producer: we are both starved");
			m_bptr[Access.get].m_req = count;
			m_bptr[Access.put].m_req = 0;
			rdn++;
			m_cond.notify();
			// Loop until our request is fulfilled
			debug(circularbuffer) stderr.writeln("consumer enters wait");
			rdw++;
			do {
				m_cond.wait();
			} while (m_bptr[Access.get].m_req == count);
			debug(circularbuffer) stderr.writeln("consumer exits wait");
		}
	}

	void ensureMappable(Access acc)(immutable ℕ count)
	out {
		assert(availableReal(acc) >= count,
		       format("ensureAvailable: failed to make %s bytes available for %s access", count, acc));
	} body {
		if (m_bptr[acc].m_knownMappable < count) {
			// Get an update on the mappable byte count.
			ℕ mappable = availableReal(acc);
			if (mappable >= count) {
				m_bptr[acc].m_knownMappable = mappable;
			} else {
		//		if (m_bptr[acc].delayedRemain >= count || availableReal(acc) >= count) return;
				// Otherwise the consumer starves, so we update two variables. m_maxRead is the largest read request ever
				// encountered and used by the buffer grow method that will be called if the producer also runs out of space now.
				acc ? producerStarve(count) : consumerStarve(count);
				// We now have >= count bytes available.
				m_bptr[acc].m_knownMappable = availableReal(acc);
			}
		}
	}

	ubyte* map(Access acc)(immutable ℕ count)
	{
		ensureMappable!acc(count);
		return m_bptr[acc].m_ptr;
	}

	ℕ availableUncommitted(immutable Access acc) const nothrow
	out(result) {
		assert(result <= m_size,
		       format("availableUncommitted: available bytes (%s) exceed buffer size (%s)", result, m_size));
	} body {
		immutable fill = atomicLoad(m_fill);
		return acc ? (m_size - fill) : fill;
	}

	ℕ availableReal(immutable Access acc) const nothrow
	out(result) {
		assert(result <= m_size,
		       format("availableReal: available bytes (%s) exceed buffer size (%s)", result, m_size)); 
	} body {
		return availableUncommitted(acc) - m_bptr[acc].m_delayed;
	}

	ℕ queryFillAtomic() const nothrow
	out(result) {
		assert(result <= m_size,
		       format("availableReal: available bytes (%s) exceed buffer size (%s)", result, m_size)); 
	} body {
		return atomicLoad(m_fill);
	}

	/**
	 * Adds or removes (if diff is negative) atomically from the fill count of the ring buffer.
	 * If uses a CAS instruction to avoid locking.
	 */
	ℕ modifyFillAtomic(ℤ diff)
	out(result) {
		assert(result <= m_size,
		       format("modifyFillAtomic: buffer fill (%s) exceed buffer size (%s) after adding %s bytes", result, m_size, diff));
	} body {
		ℕ oldFill, newFill;
		do {
			oldFill = atomicLoad(m_fill);
			newFill = oldFill + diff;
		} while (!cas(&m_fill, oldFill, newFill));
		return newFill;
	}

	/**
	 * Adds or removes (if diff is negative) from the fill count of the ring buffer.
	 * For an atomic version see modifyFillAtomic().
	 */
	ℕ modifyFill(ℤ diff)
	out(result) {
		assert(result <= m_size,
		       format("modifyFill: buffer fill (%s) exceed buffer size (%s) after adding %s bytes", result, m_size, diff));
	} body {
		return m_fill += diff;
	}

public:
	@disable this();
	@disable this(this);
	@disable this(const SCircularBuffer other);

	this(ℕ dummy)
	{
		m_cond = new Condition(new Mutex);
		m_bptr[0].m_buf = &this;
		m_bptr[0].m_acc = Access.get;
		m_bptr[0].m_counterPart = &m_bptr[1];
		m_bptr[1].m_buf = &this;
		m_bptr[1].m_acc = Access.put;
		m_bptr[1].m_counterPart = &m_bptr[0];
	}

	ref SCircularBuffer opAssign()(auto ref SCircularBuffer other)
	in { assert(m_size == 0, "Cannot assign to a circular buffer that is already in use."); }
	body {
		if (&this !is &other) {
			memcpy(&this, &other, SCircularBuffer.sizeof);
			m_bptr[0].m_buf = &this;
			m_bptr[0].m_counterPart = &m_bptr[1];
			m_bptr[1].m_buf = &this;
			m_bptr[1].m_counterPart = &m_bptr[0];
		}
		return this;
	}

	~this()
	{
		munmap(m_buf, 2 * m_size);
	}

	const(ubyte*)  mapConsumable(ℕ count) { return map!(Access.get)(count); }
	ubyte*         mapWritable  (ℕ count) { return map!(Access.put)(count); }

	void finish()
	{
		m_cond.mutex.lock();
		scope(exit) m_cond.mutex.unlock();

		m_bptr[1].releaseAndFlush(0);
		m_eof = true;
		if (m_bptr[Access.get].m_req) {
			m_bptr[Access.get].m_req = 0;
			wrn++;
			m_cond.notify();
		}
	}

	@property SBufferPtr* get() { return &m_bptr[0]; }
	@property SBufferPtr* put() { return &m_bptr[1]; }
}

//__gshared ℕ casw, casr, callr, callw;
__gshared ℕ rdw, rdn, wrw, wrn;

struct SBufferPtr
{
private:
	SCircularBuffer* m_buf;            /// Points back to the originating circular buffer.
	ubyte*           m_ptr;            /// The current pointer into the circular buffer.
	ℕ                m_mask;           /// Applying this to the read or write pointer wraps it around.
	ℕ                m_knownMappable;  /// Number of bytes ahead of the 'ptr' known to be mappable.
	ℕ                m_delayed;        /// To minimize thread synchronization, reads or writes up to this amount of bytes are cached and invisible to the other thread. Currently this is at most 1 KiB.
	shared ℕ         m_req;            /// Set to the current request in bytes when starving.
	ℕ                m_max;            /// Longest request ever made in bytes; used to calculate buffer requirements.
	Access           m_acc;
	SBufferPtr*      m_counterPart;

	ℕ queryMappable()
	{
		immutable fill = m_buf.queryFillAtomic();
		return (m_acc == Access.get ? fill : m_buf.m_size - fill) - m_delayed;
	}

	void releaseAndFlush(immutable ℕ count)
	{
		// add unflushed bytes to the count
		ℤ diff = m_acc ? +count + m_delayed : -count - m_delayed;
		m_delayed = 0;
		// Is the other thread starving ?
		if (auto otherReq = atomicLoad(m_counterPart.m_req)) {
			m_buf.modifyFill(diff);
			if (m_counterPart.queryMappable() >= otherReq) {
				// Write request satisfied, notify producer
				m_buf.m_cond.mutex.lock();
				scope(exit) m_buf.m_cond.mutex.unlock();
				m_counterPart.m_req = 0;
				m_buf.m_cond.notify();
			}
		} else {
			atomicFence();  // If we are the producer, flush any written bytes from this CPU to let the consumer see them.
			m_buf.modifyFillAtomic(diff);
		}
	}

public:
	void release()(immutable ℕ count)
	in {
		assert(count <= queryMappable());
		assert(count <= m_knownMappable);
	} body { 
		m_ptr = cast(ubyte*) (cast(ℕ) m_ptr + count & m_mask);
		m_knownMappable -= count;
		if (m_delayed + count <= delayable) {
			m_delayed += count;
		} else {
			releaseAndFlush(count);
		}
	}

	void release(T)() if (!hasIndirections!T)
	{ 
		release(T.sizeof);
	}

	ubyte[] mapAvailable()
	{
		return m_ptr[0 .. m_knownMappable];
	}

	ubyte[] mapAtLeast(immutable ℕ count)
	{
		if (m_acc)
			m_buf.ensureMappable!(Access.put)(count);
		else
			m_buf.ensureMappable!(Access.get)(count);
		return mapAvailable();
	}

	ubyte[] map()(immutable ℕ count)
	{
		return mapAtLeast(count)[0 .. count];
	}

	T* map(T)() if (!hasIndirections!T)
	{
		if (m_acc)
			m_buf.ensureMappable!(Access.put)(T.sizeof);
		else
			m_buf.ensureMappable!(Access.get)(T.sizeof);
		return cast(T*) m_ptr;
	}

	// bit-wise operations

private:
	uint m_bit;

	void requireBits(uint count)
	in { assert(count <= 64); }
	body {
		// calculate required buffer space; hackish first check if the max. bits are in
		if (m_knownMappable <= 8) {
			if (count > 8 * m_knownMappable - m_bit) {
				immutable requiredBytes = (count + m_bit + 7) / 8;
				if (m_acc)
					m_buf.ensureMappable!(Access.put)(requiredBytes);
				else
					m_buf.ensureMappable!(Access.get)(requiredBytes);
			}
		}
	}

	T readBitsImpl(T, bool peek)(uint count)
	{
		requireBits(count);

		// read bits
		auto reading = m_ptr;
		T result = *reading >> m_bit;
		if (count < 8 - m_bit) {
			result &= (1 << count) - 1;
			static if (!peek) m_bit += count;
		} else {
			uint accu = 8 - m_bit;
			int remaining = count - accu;
			reading++;
			while (remaining >= 8) {
				result |= *(reading++) << accu;
				accu += 8;
				remaining -= 8;
			}
			result |= (*reading & ((1 << remaining) - 1)) << accu;
			static if (!peek) {
				release(reading - m_ptr);
				m_bit = remaining;
			}
		}
		return result;
	}
	
public:
	T peekBits(T)(uint count) if (isUnsigned!T)
	in { assert(count <= T.sizeof * 8, "integer data type too small to hold requested bits"); }
	body {
		return readBitsImpl!(T, true)(count);
	}

	void skipBits(C : uint)(C count)
	{
		requireBits(count);
		releaseBits(count);
	}

	void releaseBits(C : uint)(C count)
	{
		auto cnt = count + m_bit;
		release(cnt / 8);
		m_bit = cnt % 8;
	}

	/// Reads a single bit from the stream
	bool readBit()
	{
		if (m_acc)
			m_buf.ensureMappable!(Access.put)(1);
		else
			m_buf.ensureMappable!(Access.get)(1);
		bool result = (*m_ptr & (1 << m_bit++)) != 0;
		if (!(m_bit &= 7)) release(1);
		return result;
	}

	auto readBits(uint count)()
	{
		// select return type
		static if (count <= 32) {
			alias T = uint;
		} else static if (count <= 64) {
			alias T = ulong;
		} else static assert("binary stream can only read up to 64 bits ar once");
		return readBitsImpl!(T, false)(count);
	}

	T readBits(T)(uint count) if (isUnsigned!T)
	in { assert(count <= T.sizeof * 8, "integer data type too small to hold requested bits"); }
	body {
		return readBitsImpl!(T, false)(count);
	}

	void skipBitsToNextByte()
	{
		if (m_bit) release(1);
		m_bit = 0;
	}
}



private:

enum delayable = 1.KiB;
enum Access { get = 0, put = 1 }
