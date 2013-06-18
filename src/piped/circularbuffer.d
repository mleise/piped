module piped.circularbuffer;

import core.atomic;
import core.stdc.string;
import core.sync.condition;
import core.sys.posix.sys.mman;
import std.algorithm;
import std.stdio;
import std.string;
import std.traits;
import sys.memarch;

import util;


class ConsumerStarvedException : Exception
{
    @safe pure nothrow this(string msg, string file = __FILE__, ℕ line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, ℕ line = __LINE__)
    {
        super(msg, file, line, next);
    }
}

class ProducerStarvedException : Exception
{
    @safe pure nothrow this(string msg, string file = __FILE__, ℕ line = __LINE__, Throwable next = null)
    {
        super(msg, file, line, next);
    }

    @safe pure nothrow this(string msg, Throwable next, string file = __FILE__, ℕ line = __LINE__)
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

	ubyte*        buf;   /// The pointer to the buffer start.
	SBufferPtr[2] bptr;
	ℕ             size;  /// published buffer size (excluding mirror pages)
	shared ℕ      fill;  /// amount unprocessed (unread) data available to the consumer
	Condition     cond;
	ℕ             heat;

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
	void grow(in ℕ optimal)
	in {
		assert(optimal);
	} body {
		debug(circularbuffer) stderr.writeln("producer initiates grow");
		immutable size = max(optimal, 2 * this.size, allocationGranularity).growToPowerOf2();
		// we must be able to split the virtual memory in half for our mirror pages...
		debug(circularbuffer) stderr.writefln("Growth request to %s KiB (%s)", size / 1024, Thread.getThis.name);
		auto bufOld = this.buf;
		this.buf = cast(ubyte*) mmap(null, 4 * size, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);

		// cut out a piece that fits our bit masking requirement and deallocate the rest
		auto cut = this.buf.alignPtrToNextMultipleOfPowerOfTwoValue(2 * size);
		debug(circularbuffer) stderr.writefln("Cutting out: %s -> %s", this.buf, cut);
		immutable pgoff = cut - this.buf;
		munmap(this.buf, pgoff);
		munmap(cut + 2 * size, 2 * size - pgoff);
		this.buf = cut;

		// map second half as mirror of first
		if (remap_file_pages(this.buf + size, size, 0, pgoff / systemPageSize, 0))
			throw new Exception("remap_file_pages failed");

		if (this.size) foreach (i; 0 .. size / this.size)
			this.buf[i * this.size .. (i+1) * this.size] = bufOld[0 .. this.size];

		// The put pointer is always adjusted relative to the buffer start as it will write into the new space ahead.
		this.bptr[Access.put].ptr += this.buf - bufOld;
		// The get pointer 'follows' the put pointer.
		this.bptr[Access.get].ptr += this.buf - bufOld;

		// "Flush" the delayed data
		this.fill -= this.bptr[Access.get].delayed;
		this.fill += this.bptr[Access.put].delayed;
		this.bptr[Access.get].delayed = 0;
		this.bptr[Access.put].delayed = 0;
		if (this.fill != 0 && this.bptr[Access.get].ptr >= this.bptr[Access.put].ptr)
			this.bptr[Access.put].ptr += this.size;

		// release old mapping
		if (bufOld) munmap(bufOld, 2 * this.size);

		// growth request is now satisfied
		immutable mask = cast(ℕ) this.buf & -size | (size - 1);
		this.bptr[0].mask = this.bptr[1].mask = mask;
		this.size = size;
	}

	void producerStarve(in ℕ count)
	out {
		immutable available = this.bptr[Access.put].queryMappable();
		assert(available >= count, format("makeWritable: failed to make %s bytes available for put access (only %s are available)", count, available));
	} body {
		this.bptr[Access.put].max.correctUpwards(count);
		this.cond.mutex.lock();
		scope(exit) this.cond.mutex.unlock();

		// Collect information on the state of affairs
		bool requestFulfilled = false;
		bool mutuallyBlocked = this.bptr[Access.get].req != 0;
		if (!mutuallyBlocked) {
			// no, so we have a chance of resolving this by waiting for the consumer to free some buffer space
			debug(circularbuffer) writefln("producer is out of buffer space and asks consumer for %s bytes", count);
			if (!this.bptr[Access.get].finished) {
				this.bptr[Access.put].req = count;
				// Now we wait for the consumer to either consume enough or starve. Either way it signals us to take action.
				debug(circularbuffer) writeln("producer enters wait");
				do {
					this.cond.wait();
				} while (this.bptr[Access.put].req == count);
				debug(circularbuffer) writeln("producer exits wait");
			}
			if (this.bptr[Access.get].finished) {
				this.bptr[Access.put].knownMappable = this.bptr[Access.put].queryMappable();
				throw new ProducerStarvedException("Consumer has finished early.");
			}
			// HINT: At this point, the consumer isn't neccessarily starving!
			// It might have seen our request, fulfilled it and went on. Eventually it might then run out of buffer and
			// starve, but those are two distinct cases.
			mutuallyBlocked = this.bptr[Access.get].req != 0;
			requestFulfilled = this.bptr[Access.put].queryMappable() >= count;
			debug(circularbuffer) if (!mutuallyBlocked && !requestFulfilled)
				stderr.writefln("logical error in makeWritable(): %s/%s", this.fill, this.size);
		}

		// Take action (not mutually blocked and yet not fulfilled should be impossible)
		if (mutuallyBlocked) {
			// We might want to grow the buffer, calculate a good buffer size
			if (this.heat < 100) this.heat += 10;
			immutable optimal = 2 * (delayable + this.bptr[Access.get].max + this.bptr[Access.put].max);
			if (optimal > this.size || (this.heat >= 100) && (this.size < 4 * optimal)) {
				grow(optimal);
				this.bptr[Access.put].req = 0;
				this.heat = 0;
			}
			// HINT: The consumer might have starved, then locked the mutex while the producer was still filling the buffer
			//       In that case we send it back to work right away. In fact, the producer might run out of free space
			//       and dead-lock if we don't.
			if (this.bptr[Access.get].req <= this.bptr[Access.get].queryMappable()) {
				this.bptr[Access.get].req = 0;
				this.cond.notify();
				if (count > this.bptr[Access.put].queryMappable()) {
					this.bptr[Access.put].req = count;
					debug(circularbuffer) writeln("producer enters wait");
					do {
						this.cond.wait();
					} while (this.bptr[Access.put].req == count);
					debug(circularbuffer) writeln("producer exits wait");
				}
			}
		} else {
			// cool down thread collision counter
			if (this.heat) this.heat--;
			if (!requestFulfilled)
				// request must have been fulfilled by consumer
				throw new Exception("Error in makeWritable, request was expected to be fulfilled by consumer");
			if (count > this.bptr[Access.put].queryMappable())
				writefln("makeWritable: %s error, expected consumer to fulfill request", Access.put); 
			this.bptr[Access.put].req = 0;
		}
	}

	/// Called when we ran out of buffer for reading (excluding unflushed bytes from the producer).
	void consumerStarve(in ℕ count)
	{
		this.bptr[Access.get].max.correctUpwards(count);
		this.cond.mutex.lock();
		scope(exit) this.cond.mutex.unlock();

		bool mutuallyBlocked = this.bptr[Access.put].req != 0;
		if (!mutuallyBlocked) {
			if (!this.bptr[Access.put].finished) {
				this.bptr[Access.get].req = count;
				do {
					this.cond.wait();
				} while (this.bptr[Access.get].req == count);
			}
			if (this.bptr[Access.put].finished && count > this.bptr[Access.get].queryMappable()) {
				this.bptr[Access.get].knownMappable = this.bptr[Access.get].queryMappable();
				throw new ConsumerStarvedException(format("Not enough data to read %s bytes", count));
			}
		} else {
			debug(circularbuffer) stderr.writeln("consumer -> producer: we are both starved");
			this.bptr[Access.get].req = count;
			this.bptr[Access.put].req = 0;
			this.cond.notify();
			// Loop until our request is fulfilled
			debug(circularbuffer) stderr.writeln("consumer enters wait");
			do {
				this.cond.wait();
			} while (this.bptr[Access.get].req == count);
			debug(circularbuffer) stderr.writeln("consumer exits wait");
		}
	}

	ℕ queryFillAtomic() const pure nothrow
	out(result) {
		assert(result <= this.size, "availableReal: available bytes exceed buffer size"); 
	} body {
		return atomicLoad(this.fill);
	}

	/**
	 * Adds or removes (if diff is negative) atomically from the fill count of the ring buffer.
	 * If uses a CAS instruction to avoid locking.
	 */
	ℕ modifyFillAtomic(in ℤ diff) pure nothrow
	out(result) {
		assert(result <= this.size, "modifyFillAtomic: buffer fill exceeds buffer size");
	} body {
		ℕ oldFill, newFill;
		do {
			oldFill = atomicLoad(this.fill);
			newFill = oldFill + diff;
		} while (!cas(&this.fill, oldFill, newFill));
		return newFill;
	}

	/**
	 * Adds or removes (if diff is negative) from the fill count of the ring buffer.
	 * For an atomic version see modifyFillAtomic().
	 */
	ℕ modifyFill(in ℤ diff) pure nothrow
	out(result) {
		assert(result <= this.size, "modifyFill: buffer fill exceeds buffer size");
	} body {
		return this.fill += diff;
	}

public:
	@disable this();
	@disable this(this);
	@disable this(const SCircularBuffer other);

	this(in ℕ dummy) pure
	{
		this.cond = new Condition(new Mutex);
		this.bptr[0].buf = &this;
		this.bptr[0].acc = Access.get;
		this.bptr[0].counterPart = &this.bptr[1];
		this.bptr[1].buf = &this;
		this.bptr[1].acc = Access.put;
		this.bptr[1].counterPart = &this.bptr[0];
	}

	ref SCircularBuffer opAssign()(auto ref SCircularBuffer other)
	in { assert(this.size == 0, "Cannot assign to a circular buffer that is already in use."); }
	body {
		if (&this !is &other) {
			memcpy(&this, &other, SCircularBuffer.sizeof);
			this.bptr[0].buf = &this;
			this.bptr[0].counterPart = &this.bptr[1];
			this.bptr[1].buf = &this;
			this.bptr[1].counterPart = &this.bptr[0];
		}
		return this;
	}

	~this()
	{
		munmap(this.buf, 2 * this.size);
	}

	@property SBufferPtr* get() pure nothrow { return &this.bptr[0]; }
	@property SBufferPtr* put() pure nothrow { return &this.bptr[1]; }
}

struct SBufferPtr
{
private:
	SCircularBuffer* buf;            /// Points back to the originating circular buffer.
	ubyte*           ptr;            /// The current pointer into the circular buffer.
	ℕ                mask;           /// Applying this to the read or write pointer wraps it around.
	ℕ                knownMappable;  /// Number of bytes ahead of the 'ptr' known to be mappable.
	ℕ                delayed;        /// To minimize thread synchronization, reads or writes up to this amount of bytes are cached and invisible to the other thread. Currently this is at most 1 KiB.
	shared ℕ         req;            /// Set to the current request in bytes when starving.
	ℕ                max;            /// Longest request ever made in bytes; used to calculate buffer requirements.
	Access           acc;            /// The buffer access mode of this pointer (get or put).
	SBufferPtr*      counterPart;    /// The other buffer pointer.
	bool             finished;       /// Set by the user of this pointer to signal either the end of produced data, or that no more data will be consumed.

	ℕ queryMappable() const pure nothrow
	{
		immutable fill = this.buf.queryFillAtomic();
		return (this.acc == Access.get ? fill : this.buf.size - fill) - this.delayed;
	}

	void commitAndFlush(in ℕ count)
	{
		// add unflushed bytes to the count
		ℤ diff = this.acc ? +count + this.delayed : -count - this.delayed;
		this.delayed = 0;
		// Is the other thread starving ?
		if (auto otherReq = atomicLoad(this.counterPart.req)) {
			this.buf.modifyFill(diff);
			if (this.counterPart.queryMappable() >= otherReq) {
				// Write request satisfied, notify producer
				this.buf.cond.mutex.lock();
				scope(exit) this.buf.cond.mutex.unlock();
				this.counterPart.req = 0;
				this.buf.cond.notify();
			}
		} else {
			atomicFence();  // If we are the producer, flush any written bytes from this CPU to let the consumer see them.
			this.buf.modifyFillAtomic(diff);
		}
	}

	void ensureMappable(in ℕ count)
	out {
		assert(queryMappable() >= count, "ensureMappable: failed to make enough bytes available");
	} body {
		if (this.knownMappable >= count) return;

		// Get an update on the mappable byte count.
		ℕ mappable = queryMappable();
		if (mappable >= count) {
			this.knownMappable = mappable;
		} else {
			// Otherwise the consumer starves, so we update two variables. this.maxRead is the largest read request ever
			// encountered and used by the buffer grow method that will be called if the producer also runs out of space now.
			this.acc ? this.buf.producerStarve(count) : this.buf.consumerStarve(count);
			// We now have >= count bytes available.
			this.knownMappable = queryMappable();
		}
	}

public:
	void commit()(in ℕ count)
	in {
		assert(count <= this.knownMappable);
	} body { 
		this.ptr = cast(ubyte*) (cast(ℕ) this.ptr + count & this.mask);
		this.knownMappable -= count;
		if (this.delayed + count <= delayable)
			this.delayed += count;
		else
			commitAndFlush(count);
	}

	void commit(T)() if (!hasIndirections!T)
	{ 
		commit(T.sizeof);
	}

	ubyte[] mapAvailable() pure nothrow
	{
		return this.ptr[0 .. this.knownMappable];
	}

	ubyte[] mapAtLeast(in ℕ count)
	{
		ensureMappable(count);
		return mapAvailable();
	}

	ubyte[] map()(in ℕ count)
	{
		return mapAtLeast(count)[0 .. count];
	}

	T* map(T)() if (!hasIndirections!T)
	{
		ensureMappable(T.sizeof);
		return cast(T*) this.ptr;
	}

	void finish()
	{
		this.buf.cond.mutex.lock();
		scope(exit) this.buf.cond.mutex.unlock();

		this.commitAndFlush(0);
		this.finished = true;
		if (this.counterPart.req) {
			this.counterPart.req = 0;
			this.buf.cond.notify();
		}
	}

private: // bit-wise operations...
	uint bit;

	ℕ readBitsImpl(T)(bool peek, in uint count)
	in { 
		assert(count <= ℕ.sizeof * 8 - 7);
	} body {
		immutable ℕ mask = (1 << count) - 1;

		ℕ value;
		if (this.knownMappable >= ℕ.sizeof) {
			value = *cast(ℕ*) this.ptr >> this.bit & mask;
		} else {
			immutable requiredBytes = (count + this.bit + 7) / 8;
			if (requiredBytes > this.knownMappable) {
				ensureMappable(requiredBytes);
			}
			(cast(ubyte*) &value)[0 .. requiredBytes] = this.ptr[0 .. requiredBytes];
			value = value >> this.bit & mask;
		}
		if (!peek) commitBits(count);
		return value;
	}

public:
	auto peekBits(T)(in uint count)
	{
		return readBitsImpl!T(true, count);
	}

	void skipBits(in uint count)
	{
		immutable requiredBytes = (count + this.bit + 7) / 8;
		if (requiredBytes > this.knownMappable)
			ensureMappable(requiredBytes);
		commitBits(count);
	}

	void commitBits(in uint count)
	{
		immutable cnt = count + this.bit;
		commit(cnt / 8);
		this.bit = cnt % 8;
	}

	/// Reads a single bit from the stream
	bool readBit()
	{
		ensureMappable(1);
		bool result = (*this.ptr & (1 << this.bit++)) != 0;
		if (!(this.bit &= 7)) commit(1);
		return result;
	}

	auto readBits(uint count)()
	{
		return readBits!ubyte(count);
	}

	auto readBits(T)(in uint count)
	{
		return readBitsImpl!T(false, count);
	}

	void skipBitsToNextByte()
	{
		if (this.bit) commit(1);
		this.bit = 0;
	}
}



private:

enum delayable = 1.KiB;
enum Access { get = 0, put = 1 }
