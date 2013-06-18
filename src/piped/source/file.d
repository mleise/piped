module piped.source.file;

import std.stdio;

import util;
import piped.threads;


class CFileThread : CSequencerThread
{
private:
	File file;

protected:
	override void run()
	{
		auto put = this.buffer.put;
		while (!this.file.eof) {
			auto mapped = put.map(64.KiB);
			auto read = this.file.rawRead(mapped[0 .. 64.KiB]);
			put.commit(read.length);
		}
	}

public:
	this(File file)
	{
		super("thread reading '" ~ file.name ~ "'");
		this.file = file;
	}
}
