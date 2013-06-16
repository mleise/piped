module sequencer.algorithm.gzip;

import core.atomic;
import core.stdc.stdlib;
import std.algorithm;
import std.exception;
import std.range;
import std.string;
import std.traits;

import defs;
import sequencer.circularbuffer;
import sequencer.threads;


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
	CSequencerThread supplier;
	SBufferPtr* src;

	@disable this();

	this(CSequencerThread supplier) pure nothrow
	{
		this.supplier = supplier;
		this.src      = supplier.source;
	}

	const(char)[] mapStringZ()
	{
		ubyte[] strz = null;
		ubyte* p, e;
		do {
			ℕ pos = strz.length;
			strz = this.src.mapAtLeast(strz.length + 1);
			p = strz.ptr + pos;
			e = strz.ptr + strz.length;
			while (p !is e && *p != 0) { p++; }
		} while (p is e);
		return cast(char[]) strz[0 .. p - strz.ptr];
	}

public:
	int opApply(in int delegate(string fname, CInflateThread inflator) dg)
	{
		try while (true) {
			// process each gzip member
			auto member = this.src.map!GZipMember();
			if (member.id != GZipMember.init.id)
				throw new Exception("Not a gzip member");
			if (member.cm != 8)
				throw new Exception("GZip member is not deflate compressed");
			auto flags = member.flg;
			this.src.commit!GZipMember();

			// FEXTRA
			if (flags & 4) {
				immutable extraLength = *this.src.map!ushort();
				this.src.commit!ushort();
				this.src.commit(extraLength);
			}

			// FNAME
			string fname = null;
			if (flags & 8) {
				fname = mapStringZ().idup;
				this.src.commit(fname.length + 1);
			}

			// COMMENT
			if (flags & 16) {
				auto comment = mapStringZ();
				this.src.commit(comment.length + 1);
			}

			// FHCRC
			if (flags & 2)   
				this.src.commit!ushort();

			auto inflator = new CInflateThread(this.supplier, false);
			inflator.start();
			immutable result = dg(fname, inflator);
			inflator.skipOver();
			auto get = inflator.source;
			try while (true) {
				auto data = get.mapAtLeast(1);
				get.commit(data.length);
			} catch (EndOfStreamException) {
				// we want to get here quickly
			}
			if (inflator.isRunning) {
				inflator.join();
			}

			this.src.commit!uint();  // CRC32
			this.src.commit!uint();  // ISIZE

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
	enum WINDOW_SIZE = 32.KiB;
	enum END_OF_BLOCK = 256;
	enum CODE_LENGTHS = 19;
	static immutable ubyte[CODE_LENGTHS] CODE_LENGTH_ORDER =
		[ 16,17,18,0,8,7,9,6,10,5,11,4,12,3,13,2,14,1,15 ];

	SBufferPtr* src;
	shared bool _skipOver  = false;
	bool        lastBlock  = false;
	ℕ           kept       = 0;

	this(CSequencerThread supplier, in bool drainsSupplier)
	{
		super(supplier);
		this.src = supplier.source;
		this.autoJoin = drainsSupplier;
	}

	void moveWindow(in ℕ fill)
	{
		if (fill <= WINDOW_SIZE) {
			// We are still filling the sliding window.
			this.kept = fill;
		} else {
			// We can commit parts of the buffer that lie behind the sliding window.
			this.buffer.put.commit(fill - WINDOW_SIZE);
			if (this.kept < WINDOW_SIZE) this.kept = WINDOW_SIZE;
		}
	}

	void inflated(in ubyte data)
	{
		// Write to the position behind what we kept as the sliding window.
		auto sink = &this.buffer.put.map(this.kept + 1)[this.kept];
		*sink = data;
		// Can we can commit parts of the buffer that lie behind the sliding window ?
		if (this.kept == WINDOW_SIZE) this.buffer.put.commit(1);
		// No, we are still filling the sliding window.
		else this.kept++;
	}

	void inflated(in ubyte[] data)
	{
		// write to the position behind what we kept as the sliding window
		auto fill = this.kept + data.length;
		auto sink = &this.buffer.put.map(fill)[this.kept];
		memcpy(sink, data.ptr, data.length);
		moveWindow(fill);
	}

	void recallBytes(in ℕ back, ℕ length)
	{
		immutable fill = this.kept + length;  // Calculate size of the current window plus the bytes to be cloned.
		auto mapped = this.buffer.put.map(fill);  // We temporarily need buffer space for both.
		auto dst = &mapped[this.kept];  // Get a pointer to the end of the window.
		auto src = dst - back;  // Pointer to the bytes that we want to clone.
		while (length--) *dst++ = *src++;
		moveWindow(fill);
	}

	/**
	 * Causes the thread to read any remaining blocks as fast as possible without providing output.
	 * The thread is then joined automatically, since its work is done.
	 */
	void skipOver() pure nothrow
	{
		atomicStore(this._skipOver, true);
	}

	void decodeBlock(bool needResult)()
	{
		this.lastBlock = this.src.readBit();
		immutable mode = this.src.readBits!2();
		debug(gzip) writefln("block - last: %s, mode: %s", this.lastBlock, mode);

		final switch (mode) {
			case 0:  // literal data
				this.src.skipBitsToNextByte();

				// 16 bit block length
				auto length = *this.src.map!ushort();
				this.src.commit!ushort();
				// skip complementary block length
				immutable complement = *this.src.map!ushort();
				this.src.commit!ushort();
				if (length != 0xFFFF - complement)
					throw new Exception("Literal block length and it's complement don't match");

				// copy
				while (length) {
					auto orig = this.src.mapAtLeast(1);
					immutable blockSize = min(length, orig.length);
					static if (needResult) inflated(orig[0 .. blockSize]);
					this.src.commit(blockSize);
					length -= blockSize;
				}
				break;
			case 1:  // static huffman
				inflateBlock!needResult(DEFAULT_TREE);
				break;
			case 2:  // dynamic huffman
				immutable numLiterals   = 257 + this.src.readBits!5();
				immutable numDistance   =   1 + this.src.readBits!5();
				immutable numCodeLength =   4 + this.src.readBits!4();

				ubyte[CODE_LENGTHS] codeLength = 0;
				foreach (i; 0 .. numCodeLength)
					codeLength[CODE_LENGTH_ORDER[i]] = cast(ubyte) this.src.readBits!3();
				HuffmanTree codeStrings = HuffmanTree(codeLength);

				ushort lastToken = 0;
				ubyte[288 + 32] bitLengths = void;
				ℕ bitLengthsLength;
				while (bitLengthsLength < numLiterals + numDistance) {
					ushort token = nextToken(codeStrings);
					ℕ howOften = 0;

					if (token < 16) {
						howOften = 1;
						lastToken = token;
					} else if (token == 16) {
						howOften = 3 + this.src.readBits!2();
					} else if (token == 17) {
						howOften = 3 + this.src.readBits!3();
						lastToken = 0;
					} else if (token == 18) {
						howOften = 11 + this.src.readBits!7();
						lastToken = 0;
					} else {
						throw new Exception("Invalid data");
					}

					while (howOften--)
						bitLengths[bitLengthsLength++] = cast(ubyte) lastToken;
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
		uint token;
		while ((token = nextToken(tree)) != END_OF_BLOCK) {
			if (token < END_OF_BLOCK) { // simple token
				static if (needResult) inflated(cast(ubyte) token);
			} else {
				// Get the length of the byte stream to duplicate. Using no table lookup for trivial cases.
				ℕ length = void;
				if (token <= 264) {
					length = token - 254;
				} else if (token == 285) {
					length = 258;
				} else {
					token -= 257;
					uint lengthExtra = LENGTH_EXTRA[token];
					static if (needResult) {
						length = LENGTH_BASE[token];
						length += this.src.readBits!ubyte(lengthExtra);
					} else {
						this.src.skipBits(lengthExtra);
					}
				}

				// Get another token representing the distance.
				ℕ distanceCode = void;
				if (literalDistance)
					distanceCode = this.src.readBits!5().reverseBits(5); // fixed tree
				else
					distanceCode = nextToken(distanceTree); // dynamic tree

				uint distanceExtra = DISTANCE_EXTRA[distanceCode/2];
				static if (needResult) {
					ℕ distance = DISTANCE_BASE[distanceCode];
					distance  += this.src.readBits!ushort(distanceExtra);

					// byte-wise copy
					debug(gzip) writefln("Copy of %s bytes from %s bytes back", length, distance);
					assert(distance < WINDOW_SIZE);
					assert(length <= WINDOW_SIZE);
					recallBytes(distance, length);
				} else {
					this.src.skipBits(distanceExtra);
				}
			}
		}
	}

	ushort nextToken(ref const HuffmanTree tree)
	{
		immutable compareTo = this.src.peekBits!ushort(15);

		version (fulltree) {
			const leaf = tree[compareTo];
			this.src.commitBits(leaf.numBits);
			debug(gzip) writefln("Read token %s", leaf.code);
			return leaf.code;
		} else {
			auto mask = 1 << tree.instantMaxBit;
			foreach (bits; tree.instantMaxBit .. tree.maxBits + 1) {
				const leaf = tree[compareTo & (mask - 1)];

				if (leaf.numBits <= bits) {
					assert(leaf.numBits <= tree.maxBits);
					this.src.commitBits(leaf.numBits);
					debug(gzip) writefln("Read token %s", leaf.code);
					return leaf.code;
				}
				mask <<= 1;
			}
			throw new Exception("Invalid token");
		}
	}

protected:
	override void run()
	{
		// flush sliding window to buffer after decoding in any case
		scope(exit) this.buffer.put.commit(this.kept);
		do {
			if (atomicLoad(this._skipOver))
				decodeBlock!false();
			else
				decodeBlock!true();
		} while (!this.lastBlock);
	}
}

immutable HuffmanTree DEFAULT_TREE = HuffmanTree(chain((cast(ubyte)8).repeat.take(144),
                                                       (cast(ubyte)9).repeat.take(112),
                                                       (cast(ubyte)7).repeat.take( 24),
                                                       (cast(ubyte)8).repeat.take(  8)));
immutable HuffmanTree EMPTY_TREE = HuffmanTree();

immutable ushort[29] LENGTH_BASE =
	[ 3, /* 258 */   4, /* 259 */   5, /* 257 */
	  6, /* 261 */   7, /* 262 */   8, /* 263 */   9, /* 264 */  10,/* 260 */
	 11, /* 266 */  13, /* 267 */  15, /* 268 */  17, /* 269 */  19,/* 265 */
	 23, /* 271 */  27, /* 272 */  31, /* 273 */  35, /* 274 */  43,/* 270 */
	 51, /* 276 */  59, /* 277 */  67, /* 278 */  83, /* 279 */  99,/* 275 */
	115, /* 281 */ 131, /* 282 */ 163, /* 283 */ 195, /* 284 */ 227,/* 280 */
	258 ];/* 285 */

immutable ubyte[29] LENGTH_EXTRA =
	[ 0, /* 258 */ 0, /* 259 */ 0, /* 260 */ 0,/* 257 */
	  0, /* 262 */ 0, /* 263 */ 0, /* 264 */ 0,/* 261 */
	  1, /* 266 */ 1, /* 267 */ 1, /* 268 */ 1,/* 265 */
	  2, /* 270 */ 2, /* 271 */ 2, /* 272 */ 2,/* 269 */
	  3, /* 274 */ 3, /* 275 */ 3, /* 276 */ 3,/* 273 */
	  4, /* 278 */ 4, /* 279 */ 4, /* 280 */ 4,/* 277 */
	  5, /* 282 */ 5, /* 283 */ 5, /* 284 */ 5,/* 281 */
	  0 ];/* 285 */

immutable ushort[32] DISTANCE_BASE =
	[   1,     2,    3,    4,    5,    7,    9,    13,    17,    25,
	   33,    49,   65,   97,  129,  193,  257,   385,   513,   769,
	 1025,  1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577,
	32769, 49153  ];/* the last two are Deflate64 only */

immutable ubyte[32/2] DISTANCE_EXTRA =
	[ 0,  0,  1,  2,  3, 4,  5,  6,  7,  8, 9, 10, 11, 12, 13, 14 ];/* the last is Deflate64 only */

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
	version (fulltree) {} else
		ubyte instantMaxBit;
	Leaf[] leaves;

public:
	this()() {}

	this(R)(R bitLengths) if ((isRandomAccessRange!R || isArray!R))
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
		version (fulltree)
			immutable treeSize = 32.KiB;
		else
			immutable treeSize = 1 << maxBits;
		if (__ctfe)
			leaves = new Leaf[](treeSize);
		else
			leaves = (cast(Leaf*) malloc(Leaf.sizeof * treeSize))[0 .. treeSize];

		ushort code = 0;
		ushort[16] nextCode;
		foreach (bits; minBits .. maxBits + 1) {
			nextCode[bits] = code;
			code += bitLengthCount[bits];
			code <<= 1;
		}

		version (fulltree) {} else {
			instantMaxBit = min(cast(ubyte) 9, maxBits);
			ushort instantMask = cast(ushort) ((1 << instantMaxBit) - 1);
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

			version (fulltree) {
				immutable step = 1 << bits;
				for (auto spread = reverse + step; spread <= 32.KiB - 1; spread += step)
					leaves[spread] = Leaf(i, bits);
			} else {
				if (bits <= instantMaxBit) {
					ushort step = cast(ushort) (1 << bits);
					for (auto spread = reverse + step; spread <= instantMask; spread += step)
						leaves[spread] = Leaf(i, bits);
				}
			}
		}
	}

	~this()
	{
		if (!__ctfe) free(leaves.ptr);
	}

	const(Leaf)* opIndex(in ℕ index) const pure nothrow
	in {
		version (fulltree) assert(index < 32.KiB);
		else               assert(index < (1 << maxBits));
	} body {
		return &leaves[index];
	}

	@property bool empty() const pure nothrow
	{
		return maxBits == 0;
	}
}

T reverseBits(T)(T value, in uint count) pure nothrow if (isUnsigned!T)
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
