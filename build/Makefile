TOOLS = merge-lines merge-sects setup-newfiles renamevars renametasks

all: ../lib/libxymonclient.a $(TOOLS)

../lib/libxymonclient.a:
	$(MAKE) -C ../lib client

merge-lines: merge-lines.c
	$(CC) -o $@ $(CFLAGS) -I../include $(PCREINCDIR) $<

merge-sects: merge-sects.c
	$(CC) -o $@ $(CFLAGS) -I../include $(PCREINCDIR) $<

setup-newfiles: setup-newfiles.c ../lib/libxymonclient.a
	$(MAKE) -C ../lib client
	$(CC) -o $@ $(CFLAGS) -I../include $(PCREINCDIR) $< ../lib/libxymonclient.a

renamevars: renamevars.c
	$(CC) -o $@ $(CFLAGS) -I../include $(PCREINCDIR) $<

renametasks: renametasks.c
	$(CC) -o $@ $(CFLAGS) -I../include $(PCREINCDIR) $<

clean:
	rm -f $(TOOLS) testfile *.o *~
