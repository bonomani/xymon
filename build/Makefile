TOOLS = merge-lines merge-sects setup-newfiles renamevars renametasks

all: ../lib/libxymonclient.a $(TOOLS)

../lib/libxymonclient.a:
	$(MAKE) -C ../lib client

merge-lines: merge-lines.c
	$(CC) -o $@ $(CFLAGS) -I../include $<

merge-sects: merge-sects.c
	$(CC) -o $@ $(CFLAGS) -I../include $<

setup-newfiles: setup-newfiles.c ../lib/libxymonclient.a
	$(MAKE) -C ../lib client
	$(CC) -o $@ $(CFLAGS) -I../include $< ../lib/libxymonclient.a

renamevars: renamevars.c
	$(CC) -o $@ $(CFLAGS) -I../include $<

renametasks: renametasks.c
	$(CC) -o $@ $(CFLAGS) -I../include $<

clean:
	rm -f $(TOOLS) testfile *.o *~
