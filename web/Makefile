XYMONLIB = ../lib/libxymon.a
XYMONLIBS = $(XYMONLIB)
XYMONCOMMLIB = ../lib/libxymoncomm.a
XYMONCOMMLIBS = $(XYMONCOMMLIB) $(SSL_LIBRARY_FLAGS) $(NETLIBS) $(LIBRTDEF)
XYMONTIMELIB = ../lib/libxymontime.a
XYMONTIMELIBS = $(XYMONTIMELIB) $(LIBRTDEF)

PROGRAMS = history.cgi eventlog.cgi report.cgi reportlog.cgi snapshot.cgi findhost.cgi csvinfo.cgi acknowledge.cgi xymonpage datepage.cgi svcstatus.cgi enadis.cgi confreport.cgi criticalview.cgi criticaleditor.cgi ackinfo.cgi statusreport.cgi boilerplate.cgi hostgraphs.cgi ghostlist.cgi notifications.cgi acknowledgements.cgi hostlist.cgi useradm.cgi chpasswd.cgi appfeed.cgi cgiwrap
CGISCRIPTS = history.sh eventlog.sh report.sh reportlog.sh snapshot.sh findhost.sh csvinfo.sh columndoc.sh datepage.sh svcstatus.sh historylog.sh confreport.sh confreport-critical.sh criticalview.sh certreport.sh nongreen.sh hostgraphs.sh ghostlist.sh notifications.sh acknowledgements.sh hostlist.sh topchanges.sh appfeed.sh appfeed-critical.sh
SECCGISCRIPTS = acknowledge.sh enadis.sh criticaleditor.sh ackinfo.sh useradm.sh chpasswd.sh

ifeq ($(DORRD),yes)
	PROGRAMS += showgraph.cgi perfdata.cgi
	CGISCRIPTS += showgraph.sh perfdata.sh
endif

CGIWRAPOBJS     = cgiwrap.o
HISTOBJS        = history.o
EVENTLOGOBJS    = eventlog.o
REPOBJS         = report.o
REPLOGOBJS      = reportlog.o
SNAPOBJS        = snapshot.o
FINDHOSTOBJS    = findhost.o
CSVINFOOBJS     = csvinfo.o
ACKCGIOBJS      = acknowledge.o
WEBPAGEOBJS     = xymonpage.o
DATEPAGEOBJS    = datepage.o
APPFEEDOBJS	= appfeed.o

SHOWGRAPHOBJS   = showgraph.o
SVCSTATUSOBJS   = svcstatus.o svcstatus-info.o svcstatus-trends.o
ENADISOBJS      = enadis.o
CRITVIEWOBJS    = criticalview.o
CRITEDITOBJS    = criticaleditor.o
ACKINFOOBJS     = ackinfo.o
CONFREPOBJS     = confreport.o
STATUSREPOBJS   = statusreport.o
MAILACKOBJS     = xymon-mailack.o
GHOSTOBJS       = ghostlist.o
NOTIFYOBJS      = notifications.o
ACKNOWLEDGEOBJS = acknowledgements.o
HOSTLISTOBJS    = hostlist.o
PERFDATAOBJS	= perfdata.o
USERADMOBJS	= useradm.o
CHPASSWDOBJS	= chpasswd.o

HOSTGRAPHSOBJS  = hostgraphs.o
BOILERPLATEOBJS = boilerplate.o


IDTOOL := $(shell if test `uname -s` = "SunOS"; then echo /usr/xpg4/bin/id; else echo id; fi)


all: $(PROGRAMS)

cgiwrap.o: cgiwrap.c
	$(CC) $(CFLAGS) -DXYMONHOME=\"$(XYMONHOME)\" -c -o $@ $<

cgiwrap: $(CGIWRAPOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(CGIWRAPOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

history.cgi: $(HISTOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(HISTOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

eventlog.cgi: $(EVENTLOGOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(EVENTLOGOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

report.cgi: $(REPOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(REPOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

reportlog.cgi: $(REPLOGOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(REPLOGOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

snapshot.cgi: $(SNAPOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(SNAPOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

findhost.cgi: $(FINDHOSTOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(FINDHOSTOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

csvinfo.cgi: $(CSVINFOOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(CSVINFOOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

acknowledge.cgi: $(ACKCGIOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(ACKCGIOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

xymonpage: $(WEBPAGEOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(WEBPAGEOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

datepage.cgi: $(DATEPAGEOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(DATEPAGEOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

showgraph.o: showgraph.c
	$(CC) $(CFLAGS) $(PCRE_INCLUDE_DIR) $(RRD_DEFS) $(RRD_INCLUDE_DIR) -c -o $@ $<

# Need NETLIBS on Solaris for getservbyname(), called by parse_url()
showgraph.cgi: $(SHOWGRAPHOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(SHOWGRAPHOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS) $(RRDLIBS)

svcstatus.cgi: $(SVCSTATUSOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(SVCSTATUSOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

enadis.cgi: $(ENADISOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(ENADISOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

statusreport.cgi: $(STATUSREPOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(STATUSREPOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

confreport.cgi: $(CONFREPOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(CONFREPOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

criticalview.cgi: $(CRITVIEWOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(CRITVIEWOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

criticalview.o: criticalview.c
	$(CC) $(CFLAGS) $(PCRE_INCLUDE_DIR) -c -o $@ $<

criticaleditor.cgi: $(CRITEDITOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(CRITEDITOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

ackinfo.cgi: $(ACKINFOOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(ACKINFOOBJS) $(XYMONCOMMLIBS)

boilerplate.cgi: $(BOILERPLATEOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(BOILERPLATEOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

hostgraphs.cgi: $(HOSTGRAPHSOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(HOSTGRAPHSOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

ghostlist.cgi: $(GHOSTOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(GHOSTOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

notifications.cgi: $(NOTIFYOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(NOTIFYOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

acknowledgements.cgi: $(ACKNOWLEDGEOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(ACKNOWLEDGEOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

hostlist.cgi: $(HOSTLISTOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(HOSTLISTOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

perfdata.o: perfdata.c
	$(CC) $(CFLAGS) $(PCRE_INCLUDE_DIR) $(RRD_DEFS) $(RRD_INCLUDE_DIR) -c -o $@ $<

# Need -lm on perfdata because it refers to isnan()
perfdata.cgi: $(PERFDATAOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(PERFDATAOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS) $(RRDLIBS) -lm

useradm.cgi: $(USERADMOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(USERADMOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

chpasswd.cgi: $(CHPASSWDOBJS) $(XYMONCOMMLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(CHPASSWDOBJS) $(XYMONCOMMLIBS) $(PCRE_LIBRARY_FLAGS)

appfeed.cgi: $(APPFEEDOBJS) $(XYMONLIB)
	$(CC) $(CFLAGS) -o $@ $(RPATHOPT) $(APPFEEDOBJS) $(XYMONCOMMLIBS) $(XYMONLIBS) $(PCRE_LIBRARY_FLAGS)


%.o: %.c
	$(CC) $(CFLAGS) -c -o $@ $<


clean:
	rm -f $(PROGRAMS) *.o *~

install: install-bin install-cgi install-man

install-bin:
ifndef PKGBUILD
	chown $(XYMONUSER) $(PROGRAMS)
	chgrp `$(IDTOOL) -g $(XYMONUSER)` $(PROGRAMS)
	chmod 755 $(PROGRAMS)
endif
	cp -fp $(PROGRAMS) $(INSTALLROOT)$(INSTALLBINDIR)/

install-cgi:
	mkdir -p $(INSTALLROOT)$(CGIDIR)
	mkdir -p $(INSTALLROOT)$(SECURECGIDIR)
ifndef PKGBUILD
	for F in $(CGISCRIPTS); do ln -f $(INSTALLROOT)$(INSTALLBINDIR)/cgiwrap $(INSTALLROOT)$(CGIDIR)/$$F; done
	for F in $(SECCGISCRIPTS); do ln -f $(INSTALLROOT)$(INSTALLBINDIR)/cgiwrap $(INSTALLROOT)$(SECURECGIDIR)/$$F; done
else
	for F in $(CGISCRIPTS); do ln -f $(INSTALLROOT)$(INSTALLBINDIR)/cgiwrap $(INSTALLROOT)$(CGIDIR)/$$F; done
	for F in $(SECCGISCRIPTS); do ln -f $(INSTALLROOT)$(INSTALLBINDIR)/cgiwrap $(INSTALLROOT)$(SECURECGIDIR)/$$F; done
endif

install-man:
ifndef PKGBUILD
	chown $(XYMONUSER) *.1 *.5 *.8
	chgrp `$(IDTOOL) -g $(XYMONUSER)` *.1 *.5 *.8
	chmod 644 *.1 *.5 *.8
endif
	mkdir -p $(INSTALLROOT)$(MANROOT)/man1 $(INSTALLROOT)$(MANROOT)/man5 $(INSTALLROOT)$(MANROOT)/man8
ifndef PKGBUILD
	chown $(XYMONUSER) $(INSTALLROOT)$(MANROOT)/man1 $(INSTALLROOT)$(MANROOT)/man5 $(INSTALLROOT)$(MANROOT)/man8
	chgrp `$(IDTOOL) -g $(XYMONUSER)` $(INSTALLROOT)$(MANROOT)/man1 $(INSTALLROOT)$(MANROOT)/man5 $(INSTALLROOT)$(MANROOT)/man8
	chmod 755 $(INSTALLROOT)$(MANROOT)/man1 $(INSTALLROOT)$(MANROOT)/man5 $(INSTALLROOT)$(MANROOT)/man8
endif
	cp -fp *.1 $(INSTALLROOT)$(MANROOT)/man1/
	cp -fp *.5 $(INSTALLROOT)$(MANROOT)/man5/
	cp -fp *.8 $(INSTALLROOT)$(MANROOT)/man8/

