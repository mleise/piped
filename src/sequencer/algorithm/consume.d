module sequencer.algorithm.consume;

import sequencer.circularbuffer;
import sequencer.threads;


void consume(T)(T source)
{
	auto consumable = source.toSequencerThread();
	consumable.addUser();
	scope(exit) consumable.removeUser();

	auto get = consumable.source;
	try while(true) {
		get.commit(get.mapAtLeast(1).length);
	} catch (ConsumerStarvedException) {
		// This is the expected outcome; not a single byte was left to copy.
	}
}

//void abort(T)(T source)
//{
//	auto consumable = source.toSequencerThread();
//	consumable.source.finish();
//	consumable.join();
//}
alias abort = consume;