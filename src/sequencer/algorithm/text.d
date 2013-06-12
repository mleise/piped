module sequencer.algorithm.text;

import core.atomic;
import std.algorithm;
import std.range;
public import std.string : KeepTerminator;
import std.stdio;

import defs;
import sequencer.circularbuffer;
import sequencer.threads;
import core.thread;
import core.thread;
import core.sys.posix.pthread;


auto splitLines(T)(T source, KeepTerminator keepTerminator = KeepTerminator.no)
{
	return SLineRange(source.toSequencerThread(), keepTerminator);
}

private struct SLineRange
{
private:
	CSequencerThread m_supplier;
	SCircularBuffer* m_source;
	ℕ m_lineSize;
	ℕ m_lineLength;
	const(char)[] m_peek;
	bool m_empty;
	bool m_removeTerminator;
	SBufferPtr* m_get;

	@disable this();

	this(CSequencerThread supplier, KeepTerminator keepTerminator)
	{
		m_supplier = supplier;
		m_get = supplier.source;
		m_removeTerminator = (keepTerminator == KeepTerminator.no);
		popFront();
	}

public:
	@property bool empty() const
	{
		return m_empty;
	}

	void popFront()
	in   { assert(!empty); }
	body {
		if (m_lineSize) {
			m_get.release(m_lineSize);
			m_peek = m_peek[m_lineSize .. $];
			broken = m_lineSize < 60;
		}
		auto b = m_peek.ptr;
		try while (true) {
			const e = m_peek.ptr + m_peek.length;
			while (b !is e) {
				if (*(b++) == '\n') {
					m_lineLength = m_lineSize = b - m_peek.ptr;
					if (m_removeTerminator)
						m_lineLength--;
					if (m_lineLength > 80)
						stderr.writefln("IT HAPPENED AGAIN!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!");
					return;
				}
			}
			ℕ pos = m_peek.length;
			m_peek = cast(const(char)[]) m_get.mapAtLeast(pos + 1);
//			if (pos + 1 > m_peek.length)
//				stderr.writeln("test");
			b = m_peek.ptr + pos;
//			if (*b != 'N' && *b != '>' && *b != '\n')
//				stderr.writefln("arrrg: '%s'", *b);
		} catch (EndOfStreamException e) {
			m_peek = cast(const(char)[]) m_get.mapAvailable();
			m_lineLength = m_lineSize = m_peek.length;
			m_empty = (m_lineSize == 0);
			if (m_empty) {
				m_supplier.join();
			}
		}
	}

	@property const(char)[] front() const
	in   { assert(!m_empty); }
	body {
		return m_peek[0 .. m_lineLength];
	}
}
static assert(isInputRange!SLineRange);
