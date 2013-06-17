module sequencer.algorithm.text;

public import std.string : KeepTerminator;

import std.range : isInputRange;

import defs;
import sequencer.circularbuffer;
import sequencer.threads;


/**
 * Splits a source into Unix text lines. If 'keepTerminator' is set, \n will be kept on the resulting lines,
 * except maybe on the last line where it may not be in the source.
 */
auto splitLines(T)(T source, in KeepTerminator keepTerminator = KeepTerminator.no)
{
	return LineRange(source.toSequencerThread(), keepTerminator);
}

private struct LineRange
{
private:
	CSequencerThread supplier;          /// The thread that supplies us with text to line break. This pointer keeps it from being collected by the GC before we can read out all buffer data. It is also used to join that thread with ours, once all text is read.
	SBufferPtr*      get;               /// A shortcut to the supplier thread's 'get' buffer pointer.
	ℕ                lineSize;          /// Byte size of the current line including line-break characters.
	ℕ                lineLength;        /// The line length as returned by front(). Same as lineSize if line-breaks are kept.
	const(char)[]    peek;              /// A range of bytes that lie ahead in the buffer. It is extended when no line-break is found in it.
	bool             _empty;            /// Set, after the last available line has been popped.
	bool             removeTerminator;  /// If set, the returned lines will have line-break characters removed.

	@disable this();

	this(CSequencerThread supplier, in KeepTerminator keepTerminator)
	{
		this.supplier = supplier;
		this.get = supplier.source;
		this.removeTerminator = (keepTerminator == KeepTerminator.no);
		this.supplier.addUser();
		this.popFront();
	}

public:
	this(this) { this.supplier.addUser(); }

	~this() { this.supplier.removeUser(); }

	@property bool empty() const pure nothrow { return this._empty; }

	void popFront()
	in   { assert(!this._empty); }
	body {
		// popFront() 101: Release the buffer space we no longer need to expose through front().
		this.get.commit(this.lineSize);
		this.peek.drop(this.lineSize);
		// Look for the next line-break in 'peek', eventually fetching more buffer space from our supplier.
		auto b = this.peek.ptr;
		try while (true) {
			// End or sentinel pointer
			const e = this.peek.ptr + this.peek.length;
			// First we skip as many blocks of machine word size that don't contain line-breaks as possible.
			for (auto skipFast = (e - b) / ℕ.sizeof; skipFast; skipFast--) {
				if (contains!'\n'( *(cast(ℕ*) b) )) break;
				b += ℕ.sizeof;
			}
			// Then we examine byte by byte and return when we find a complete line of text.
			while (b !is e) {
				if (*b == '\n') {
					this.lineLength = this.lineSize = b - this.peek.ptr + 1;
					this.lineLength -= this.removeTerminator;
					return;
				}
				b++;
			}
			// We require at least one more byte. If the supply is out, we catch the exception below.
			immutable pos = this.peek.length;
			this.peek = cast(const(char)[]) this.get.mapAtLeast(pos + 1);
			b = this.peek.ptr + pos;
		} catch (ConsumerStarvedException e) {
			// There is no more line-breaks in the text. We might still have an unterminated line in
			// the buffer though. Note: We get here a second time, if '_empty' isn't set below yet.
			this.peek = cast(const(char)[]) this.get.mapAvailable();
			this.lineLength = this.lineSize = this.peek.length;
			this._empty = (this.lineSize == 0);
		}
	}

	@property const(char)[] front() const pure nothrow
	in   { assert(!this._empty); }
	body {
		return this.peek[0 .. this.lineLength];
	}
}
static assert(isInputRange!LineRange);
