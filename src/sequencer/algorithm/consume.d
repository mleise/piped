module sequencer.algorithm.consume;

import sequencer.circularbuffer;
import sequencer.threads;


void consume(T)(T source)
{
	auto consumable = source.toSequencerThread();
	auto get = consumable.source;
	try while(true) {
		get.release(get.mapAtLeast(1).length);
	} catch (EndOfStreamException) {
		// this is the expected outcome; not a single byte was left to copy
	}
}
