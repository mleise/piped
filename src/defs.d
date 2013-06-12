module defs;

import core.bitop;
import std.traits;

alias ℕ = size_t;
alias ℤ = ptrdiff_t;

pure nothrow:

T growPtrToNextMultipleOfPowerOfTwoValue(T)(T ptr, ℕ pot) if (isPointer!T)
in { assert(pot > 0 && pot.isPowerOf2); }
body { return cast(T) ((cast(ℕ) ptr + (pot - 1)) & -pot); }
unittest { assert(growPtrToNextMultipleOfPowerOfTwoValue(cast(void*) 65, 64) == cast(void*) 128); }

@safe:

@property ℕ KiB(ℕ n) { return 1024 * n; }
@property ℕ MiB(ℕ n) { return 1024 * 1024 * n; }
@property ℕ GiB(ℕ n) { return 1024 * 1024 * 1024 * n; }

@property bool isPowerOf2(ℕ n)
in { assert(n > 0); }
body { return (n & n - 1) == 0; }

T growToNextMultipleOf(T, U)(T value, U to) if (isUnsigned!U)
in { assert(to > 0 && T.max / to >= value / to); }
body { return (value + (to - 1)) / to * to; }

ℕ growToPowerOf2(ℕ v)
in { assert(v >= 1 && v <= (ℕ.max >> 1) + 1); }
body { return v - 1 ? 1 << (bsr(v - 1) + 1) : 1; }

void correctUpwards(T)(ref T val, T newMinimum) { if (val < newMinimum) val = newMinimum; }

enum stackTrace = q{ try { throw new Exception(null); } catch (Exception e) { writeln(e.info); } };