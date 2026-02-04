TOOLS = merge-lines merge-sects setup-newfiles renamevars renametasks

all: ../lib/libxymonclient.a $(TOOLS)

../lib/libxymonclient.a:
	$(MAKE) -C ../lib client

merge-lines: merge-lines.c
	$(CC) -o $@ $(CFLAGS) $<

merge-sects: merge-sects.c
	$(CC) -o $@ $(CFLAGS) $<

setup-newfiles: setup-newfiles.c ../lib/libxymonclient.a
	$(MAKE) -C ../lib client
	$(CC) -o $@ $(CFLAGS) $< ../lib/libxymonclient.a

renamevars: renamevars.c
	$(CC) -o $@ $(CFLAGS) $<

renametasks: renametasks.c
	$(CC) -o $@ $(CFLAGS) $<

clean:
	rm -f $(TOOLS) testfile *.o *~
