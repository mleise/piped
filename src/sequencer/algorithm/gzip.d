module sequencer.algorithm.gzip;

import core.atomic;
import core.stdc.stdlib;
import core.stdc.string;
import std.stdio;
import std.string;
import etc.c.zlib;
import std.file;
import std.traits;
import std.algorithm;
import std.exception;
import std.range;
import std.conv;

import defs;
import sequencer.circularbuffer;
import sequencer.threads;
import core.thread;


/**
 * GZip files are - simply put - a header and footer around the DEFLATE algorithm. A compressed file inside
 * a GZip file is called a member. Multiple members can appear in a single GZip archive.
 * gzip() returns a range that iterated over each GZip member as a pair of original file name and an
 * inflation thread, that can be passed on to other algorithms like splitLines().
 */
auto gzip(T)(T source)
{
	return GZipRange(source.toSequencerThread());
}



private:

struct GZipRange
{
private:
	CSequencerThread m_supplier;
	SBufferPtr* m_src;
	bool delegate(const(char)[] fileName) m_filter;

	@disable this();

	this(CSequencerThread supplier)
	{
		m_supplier = supplier;
		m_src      = supplier.source;
	}

	const(char)[] mapStringZ()
	{
		ubyte[] strz = null;
		ubyte* p, e;
		do {
			ℕ pos = strz.length;
			strz = m_src.mapAtLeast(strz.length + 1);
			p = strz.ptr + pos;
			e = strz.ptr + strz.length;
			while (p !is e && *p != 0) { p++; }
		} while (p is e);
		return cast(char[]) strz[0 .. p - strz.ptr];
	}

public:
	int opApply(int delegate(string fname, CInflateThread inflator) dg)
	{
		try while (true) {
			// process each gzip member
			auto member = m_src.map!GZipMember();
			if (member.id != GZipMember.init.id)
				throw new Exception("Not a gzip member");
			if (member.cm != 8)
				throw new Exception("GZip member is not deflate compressed");
			auto flags = member.flg;
			m_src.release!GZipMember();

			// FEXTRA
			if (flags & 4) {
				immutable extraLength = *m_src.map!ushort();
				m_src.release!ushort();
				m_src.release(extraLength);
			}

			// FNAME
			string fname = null;
			if (flags & 8) {
				fname = mapStringZ().idup;
				m_src.release(fname.length + 1);
			}

			// COMMENT
			if (flags & 16) {
				auto comment = mapStringZ();
				m_src.release(comment.length + 1);
			}

			// FHCRC
			if (flags & 2)   
				m_src.release!ushort();

			auto inflator = new CInflateThread(m_supplier, false);
			inflator.start();
			immutable result = dg(fname, inflator);
			inflator.skipOver();
			auto get = inflator.source;
			try while (true) {
				auto data = get.mapAtLeast(1);
				get.release(data.length);
			} catch (EndOfStreamException) {
				// we want to get here quickly
			}
			if (inflator.isRunning) {
				inflator.join();
			}

			m_src.release!uint();  // CRC32
			m_src.release!uint();  // ISIZE

			if (result) return result;
		} catch (EndOfStreamException) {
			// this is the expected outcome after processing all gzip members
		}
		return 0; 
	}
}

align(1) struct GZipMember
{
	ubyte[2] id = [0x1f, 0x8b];
	ubyte cm = 8; // compression mode: deflate
	ubyte flg;  // bits: 0 - FTEXT, 1 - FHCRC, 2 - FEXTRA, 3 - FNAME, 4 - FCOMMENT
	uint mtime;
	ubyte xfl;
	ubyte os;
}
static assert(GZipMember.sizeof == 10);

final class CInflateThread : CAlgorithmThread
{
private:
	enum ℕ WINDOW_SIZE = 32.KiB;
	enum END_OF_BLOCK = cast(ushort) 256;
	enum CODE_LENGTHS = 19;
	static immutable ubyte[CODE_LENGTHS] CODE_LENGTH_ORDER = [ 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 ];

	SBufferPtr* m_src;
	SBufferPtr* m_dst;
	shared bool m_skipOver = false;
	bool        m_lastBlock = false;
	ℕ           m_kept = 0;
	bool        m_join = false;

	this(CSequencerThread supplier, bool drainsSupplier)
	{
		super(supplier);
		m_src = m_supplier.source;
		m_dst = m_buffer.put;
		m_autoJoin = drainsSupplier;
	}

	void moveWindow(ℕ fill)
	{
		if (fill <= WINDOW_SIZE) {
			// we are still filling the sliding window
			m_kept = fill;
		} else {
			// we can commit parts of the buffer that lie behind the sliding window
			m_buffer.put.release(fill - WINDOW_SIZE);
			m_kept = WINDOW_SIZE;
		}
	}

	void inflated(ubyte data)
	{
		// write to the position behind what we kept as the sliding window
		auto sink = &m_buffer.put.map(m_kept + 1)[m_kept];
		*sink = data;
		if (m_kept == WINDOW_SIZE) {
			// we can commit parts of the buffer that lie behind the sliding window
			m_buffer.put.release(1);
		} else {
			// we are still filling the sliding window
			m_kept++;
		}
	}

	void inflated(ubyte[] data)
	{
		// write to the position behind what we kept as the sliding window
		auto fill = m_kept + data.length;
		auto sink = &m_buffer.put.map(fill)[m_kept];
		memcpy(sink, data.ptr, data.length);
		moveWindow(fill);
	}

	void recallBytes(ℕ back, ℕ length)
	{
		auto fill   = m_kept + length;
		auto mapped = m_buffer.put.map(fill);
		auto sink   = &mapped[m_kept];
		auto dst = &mapped[m_kept];
		auto src = dst - back;
		const sentinel = dst + length;
		while (dst !is sentinel) {
			*(dst++) = *(src++);
		}
		moveWindow(fill);
	}

	/**
	 * Causes the thread to read any remaining blocks as fast as possible without providing output.
	 * The thread is then joined automatically, since its work is done.
	 */
	void skipOver()
	{
		atomicStore(m_skipOver, true);
	}

	void decodeBlock(bool needResult)()
	{
		m_lastBlock = m_src.readBit();
		immutable mode = m_src.readBits!2();
		debug(gzip) writefln("block - last: %s, mode: %s", m_lastBlock, mode);

		final switch (mode) {
			case 0:  // literal data
				m_src.skipBitsToNextByte();

				// 16 bit block length
				auto length = *m_src.map!ushort();
				m_src.release!ushort();
				// skip complementary block length
				immutable complement = *m_src.map!ushort();
				m_src.release!ushort();
				if (length != 0xFFFF - complement)
					throw new Exception("Literal block length and it's complement don't match");

				// copy
				while (length) {
					auto orig = m_src.mapAtLeast(1);
					immutable blockSize = min(length, orig.length);
					static if (needResult) {
						inflated(orig[0 .. blockSize]);
					}
					m_src.release(blockSize);
					length -= blockSize;
				}
				break;
			case 1:  // static huffman
				inflateBlock!needResult(DEFAULT_TREE);
				break;
			case 2:  // dynamic huffman
				immutable numLiterals   = 257 + m_src.readBits!5();
				immutable numDistance   =   1 + m_src.readBits!5();
				immutable numCodeLength =   4 + m_src.readBits!4();

				ubyte[CODE_LENGTHS] codeLength = 0;
				foreach (i; 0 .. numCodeLength) {
					codeLength[CODE_LENGTH_ORDER[i]] = cast(ubyte) m_src.readBits!3();
				}
				HuffmanTree codeStrings = HuffmanTree(codeLength);

				ushort lastToken = 0;
				ubyte[288 + 32] bitLengths = void;
				ℕ bitLengthsLength;
				while (bitLengthsLength < numLiterals + numDistance) {
					ushort token = nextToken(codeStrings);
					uint howOften = 0;

					if (token < 16) {
						howOften = 1;
						lastToken = token;
					} else if (token == 16) {
						howOften = 3 + m_src.readBits!2();
					} else if (token == 17) {
						howOften = 3 + m_src.readBits!3();
						lastToken = 0;
					} else if (token == 18) {
						howOften = 11 + m_src.readBits!7();
						lastToken = 0;
					} else {
						throw new Exception("Invalid data");
					}

					while (howOften--) {
						bitLengths[bitLengthsLength++] = cast(ubyte) lastToken;
					}
				}

				// we need to split distance lengths and bit lengths into separate arrays
				ubyte[32] distanceLengths = bitLengths[numLiterals .. numLiterals + 32];
				distanceLengths[numDistance .. 32] = 0;
				bitLengths[numLiterals .. 288] = 0;

				HuffmanTree distanceTree = HuffmanTree(distanceLengths);
				HuffmanTree tree         = HuffmanTree(bitLengths[0 .. 288]);
				inflateBlock!needResult(tree, distanceTree);
				break;
		}
	}

	void inflateBlock(bool needResult)(ref const HuffmanTree tree, ref const HuffmanTree distanceTree = EMPTY_TREE)
	{
		immutable literalDistance = distanceTree.empty;
		ushort token;
		while ((token = nextToken(tree)) != END_OF_BLOCK) {
			if (token < END_OF_BLOCK) { // simple token
				static if (needResult) {
					inflated(cast(ubyte) token);
				}
			} else {
				// The length is typically looked up in a small table, but the memory access turned out to
				// add 19% overhead (in total runtime of a FASTA parser!) over calculating it here.
				uint length = void;
				if (token <= 264) {
					length = token - 254;
				} else if (token == 285) {
					length = 258;
				} else {
					uint base = token - 261;
					uint extraBits = base >> 2;
					length = (1 << (extraBits + 2)) + 3 + (base & 3) * (1 << extraBits);
					length += m_src.readBits!uint(extraBits);
				}

				uint distanceCode;
				if (literalDistance) {
					distanceCode = m_src.readBits!5().reverseBits(5); // fixed tree
				} else {
					distanceCode = nextToken(distanceTree); // dynamic tree
				}

				static if (needResult) {
					static immutable ushort[32] CopyDistance = 
						[   1,     2,    3,    4,    5,    7,    9,    13,    17,    25,
							33,    49,   65,   97,  129,  193,  257,   385,   513,   769,
							1025,  1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
							32769, 49153  ];/* the last two are Deflate64 only */
					uint distance = CopyDistance[distanceCode];
				}

				static immutable ubyte[32/2] ExtraDistanceBits =
					[ 0,  0,  1,  2,  3, 4,  5,  6,  7,  8, 9, 10, 11, 12, 13, 14  ];/* the last is Deflate64 only */
				uint moreBits = ExtraDistanceBits[distanceCode/2];

				static if (needResult) {
					distance += m_src.readBits!uint(moreBits);

					// byte-wise copy
					debug(gzip) writefln("Copy of %s bytes from %s bytes back", length, distance);
					assert(distance < WINDOW_SIZE);
					assert(length <= WINDOW_SIZE);
					recallBytes(distance, length);
				} else {
					m_src.skipBits(moreBits);
				}
			}
		}
	}

	ushort nextToken(ref const HuffmanTree tree)
	{
		immutable compareTo = m_src.peekBits!uint(tree.maxBits);

		auto mask = 1 << tree.instantMaxBit;
		foreach (bits; tree.instantMaxBit .. tree.maxBits + 1) {
			const leaf = tree[compareTo & (mask - 1)];

			if (leaf.numBits <= bits) {
				assert(leaf.numBits <= tree.maxBits);
				m_src.releaseBits(leaf.numBits);
				debug(gzip) writefln("Read token %s", leaf.code);
				return leaf.code;
			}
			mask <<= 1;
		}
          
		throw new Exception("Invalid token");
//		const leaf = tree[compareTo];
//		m_src.releaseBits(leaf.numBits);
//		debug(gzip) writefln("Read token %s", leaf.code);
//		return leaf.code;
	}

protected:
	override void run()
	{
		// flush sliding window to buffer after decoding in any case
		scope(exit) m_buffer.put.release(m_kept);
		do {
			if (atomicLoad(m_skipOver)) {
				decodeBlock!false();
			} else {
				decodeBlock!true();
			}
		} while (!m_lastBlock);
	}
}

immutable HuffmanTree DEFAULT_TREE = HuffmanTree(chain((cast(ubyte)8).repeat.take(144),
                                                       (cast(ubyte)9).repeat.take(112),
                                                       (cast(ubyte)7).repeat.take( 24),
                                                       (cast(ubyte)8).repeat.take(  8)));
immutable HuffmanTree EMPTY_TREE = HuffmanTree();

struct HuffmanTree
{
private:
	struct Leaf {
		ushort code;
		ubyte numBits;
	}
	static assert(Leaf.sizeof == 4);

	ubyte minBits;
	ubyte maxBits;
	ubyte instantMaxBit;
	Leaf[] leaves;
//	Leaf[1 << 15] leaves = void;

public:
	this()() {}

	this(R)(R bitLengths) if ((isRandomAccessRange!R || isArray!R) && is(ElementType!R == ubyte))
	{
		ushort[16] bitLengthCount = 0;
		foreach (bitLength; bitLengths) if (bitLength) {
			bitLengthCount[bitLength]++;
		}

		foreach (ubyte bits; 1 .. 16) if (bitLengthCount[bits]) {
			minBits = bits;
			break;
		}
		foreach_reverse (ubyte bits; 1 .. 16) if (bitLengthCount[bits]) {
			maxBits = bits;
			break;
		}
		enforce(maxBits > 0, "No bit lengths given for Huffman tree");
		if (__ctfe) {
			leaves = new Leaf[](1 << maxBits);
		} else {
			leaves = (cast(Leaf*) malloc(Leaf.sizeof * (1 << maxBits)))[0 .. 1 << maxBits];
		}

		instantMaxBit = min(cast(ubyte) 9, maxBits);
		ushort instantMask = cast(ushort) ((1 << instantMaxBit) - 1);

		ushort code = 0;
		ushort[16] nextCode;
		foreach (bits; minBits .. maxBits + 1) {
			nextCode[bits] = code;
			code += bitLengthCount[bits];
			code <<= 1;
		}

		foreach (ushort i; 0 .. cast(ushort) bitLengths.length) {
			ubyte bits = bitLengths[i];

			if (bits == 0) continue;

			ushort canonical = nextCode[bits];
			nextCode[bits]++;

			assert(bits <= 15);
			assert(canonical < (1 << bits), format("too many bits, cannot reverse %b in %s bits", canonical, bits));
			ushort reverse = canonical.reverseBits(bits);

			leaves[reverse] = Leaf(i, bits);

			if (bits <= instantMaxBit) {
				ushort step = cast(ushort) (1 << bits);
				for (ushort spread = cast(ushort) (reverse + step); spread <= instantMask; spread += step) {
					leaves[spread] = Leaf(i, bits);
				}
			}
//			immutable mask = (1 << maxBits) - 1;
//			immutable step = 1 << bits;
//			for (auto spread = reverse + step; spread <= mask; spread += step) {
//				leaves[spread] = Leaf(i, bits);
//			}
		}
	}

	~this()
	{
		if (!__ctfe) {
			free(leaves.ptr);
		}
	}

	Leaf opIndex(ℕ index) const pure nothrow
	{
		return leaves[index];
	}

	@property bool empty() const pure nothrow
	{
		return maxBits == 0;
	}
}

T reverseBits(T)(T value, uint count) if (isUnsigned!T)
in { assert(value < (1 << count)); }
body {
	T result = 0;
	foreach (i; 0 .. count) {
		result <<= 1;
		result |= value & 1;
		value >>= 1;
	}
	return result;
}
