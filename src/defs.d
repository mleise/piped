module defs;

import core.bitop;
import std.traits;


/// Neat shortcut for the machine word size unsigned integer.
alias ℕ = size_t;
/// Neat shortcut for the machine word size signed integer.
alias ℤ = ptrdiff_t;

/// Returns the current call stack as a string.
string stackTrace() { try { throw new Exception(null); } catch (Exception e) { return e.info.toString(); } }

pure nothrow:

/// Aligns a pointer to the closest multiple of 'pot' (a power of two), which is equal to or larger than 'value'.
T alignPtrToNextMultipleOfPowerOfTwoValue(T)(T ptr, ℕ pot) if (isPointer!T)
in { assert(pot > 0 && pot.isPowerOf2); }
body { return cast(T) ((cast(ℕ) ptr + (pot - 1)) & -pot); }
unittest { assert(growPtrToNextMultipleOfPowerOfTwoValue(cast(void*) 65, 64) == cast(void*) 128); }

@safe:

/// Returns a value multiplied by 1024.
@property ℕ KiB(ℕ n) { return 1024 * n; }
/// Returns a value multiplied by 1024².
@property ℕ MiB(ℕ n) { return 1024 * 1024 * n; }
/// Returns a value multiplied by 1024³.
@property ℕ GiB(ℕ n) { return 1024 * 1024 * 1024 * n; }

/// Returns whether the argument is an integral power of two.
@property bool isPowerOf2(ℕ n)
in { assert(n > 0); }
body { return (n & n - 1) == 0; }

/// Returns the next closest multiple of 'to' that is equal to or larger than 'value'.
T alignToUpwards(T, U)(T value, U to) if (isUnsigned!U)
in { assert(to > 0 && T.max / to >= value / to); }
body { return (value + (to - 1)) / to * to; }

/// Returns the closest power of 2, equal to or larger than the argument.
ℕ growToPowerOf2(ℕ v)
in { assert(v >= 1 && v <= (ℕ.max >> 1) + 1); }
body { return v - 1 ? 1 << (bsr(v - 1) + 1) : 1; }

/// Corrects a value upwards to a given minimum if it is lower.
void correctUpwards(T)(ref T val, T newMinimum) { if (val < newMinimum) val = newMinimum; }

/// Removes the first n items from the array by slicing.
void drop(T)(ref T[] arr, ℕ count) { arr = arr[count .. $]; }

/**
 * Template for searching a fixed value in an size_t sized memory block (i.e. 4 bytes on 32-bit, 8 byte on 64-bit)
 * See: http://graphics.stanford.edu/~seander/bithacks.html#ValueInWord
 */
bool contains(ubyte V)(size_t n)
{
	// This value results in 0x01 for each byte of a size_t value.
	enum duplicator = size_t.max / 255;
	static if (V == 0) {
		return ((n - duplicator) & ~n & (duplicator * 0x80)) != 0;
	} else {
		return contains!0(n ^ (duplicator * V));
	}
}