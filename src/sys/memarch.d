module sys.memarch;

import util;


immutable ℕ systemPageSize;
immutable ℕ allocationGranularity;

version (linux) extern(C) {

	// These are needed to create multiple views of the same physical memory pages in virtual memory on Linux
	import core.sys.posix.sys.shm;
	import core.sys.posix.sys.types;
	int remap_file_pages(void *addr, size_t size, int prot, ssize_t pgoff, int flags) nothrow;
	void *mremap(void *old_address, size_t old_size, size_t new_size, int flags, ...) nothrow;
	enum MREMAP_MAYMOVE = 1;

}



private:

/***********************************************************************************************
 *
 * Setup the global above with the system page size.
 *
 *************************************/
shared static this()
{
	version(Windows) {

		SYSTEM_INFO si;
		GetSystemInfo(&si);
		
		sSystemPageSize = si.dwPageSize;
		sAllocationGranularity = si.dwAllocationGranularity;

	} else version(linux) {

		// page size and allocation granularity are the same on Linux
		allocationGranularity = systemPageSize = __getpagesize();

	} else static assert(0);
	
}
