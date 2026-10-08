# Experimental build

This branch is `main` with the open, non-draft pull requests merged on
top, so they can be tried together before they land. It is rebuilt from
scratch, not maintained by hand: don't base work on it, and report a
problem on the pull request it comes from.

- Base: `main` at `01142d868`, built 2026-10-09.
- Merged: 55 pull requests, listed below with the head that was merged.
- Suite on the result: 205 passed, 0 skipped, 0 failed, normal and strict
  (Ubuntu 22.04, server build).
- Left out: the drafts, #308 among them.

Where two pull requests changed the same lines, the merge keeps both
changes. The places that needed a decision:

- `xymond_history`'s pidfile: #219's version (#400 says it defers to it).
- `xymonnet/Makefile`: #409's `xymonnetprobe` target with #138's
  `CARESINCDIR`.
- `xymond/Makefile` install lines: #219's `XYMONRUNDIR`, #414's static
  web directory and #598's `ext/` change, together.
- Twelve tests needed `XYMONRUNDIR` or #409's
  `lib/xymonlocator` once the pull requests adding those were merged,
  and six manual pages from #583 and #584 needed their HTML regenerated
  to link #581's `xymond_locator(8)`: one commit at the top,
  "experimental: adapt twelve tests and six manual pages".

## Pull requests

| PR | head | title |
|---|---|---|
| #111 | `15adbb0d6` | build: drop the make-era platform targets nobody builds (#85) |
| #135 | `ddab2159a` | build: make SNMP a configure option like RRD, SSL and LDAP, still off by default |
| #138 | `9b63216a1` | build: drop bundled c-ares 1.15.0, build against system c-ares |
| #150 | `998447a44` | xymon-snmpcollect: stop polling the next IP when an agent answers NOSUCHNAME |
| #151 | `f4636b17a` | svcstatus: stop the trends-page locator redirect loop with SKIPLOC (TBT 44) |
| #152 | `5c2cbca58` | do_rrd: remember an RRD exists instead of stat()ing it every update (TBT 214, devel f106d8840) |
| #154 | `3433166db` | do_rrd: check the host RRD directory only when creating a file (TBT 187, devel f106d8840) |
| #172 | `9635a4cc3` | xymonlaunch: write a task's pidfile and forward HUP with SENDHUP (TBT 65/78/79/603/780, devel 3959aae5c/fa6ae1f94/266644346) |
| #173 | `6600fe05f` | xymonlaunch: add DELAY and FAILDELAY to time a task's start and retry (TBT 125, devel 065cfec07) |
| #219 | `dd552ed5e` | build: keep pidfiles and control sockets in their own XYMONRUNDIR (TBT 3) |
| #349 | `43f8c1060` | showgraph: read an RRD's own update time, not its file's (supersedes TBT 215) |
| #399 | `bade9d3dd` | msgcache: answer ping with our identity and the age of the last delivered pull |
| #400 | `e0fa87b56` | xymond_history: confine drop/rename names, bound their path builds |
| #401 | `47ec4ec80` | dropdirectory: do not follow a symlinked target or child |
| #402 | `2aee26199` | xymond_history: refuse a symlink at the files and host dirs it writes |
| #403 | `f0348bebc` | xtree: report out-of-memory from xtreeAdd instead of leaking and crashing |
| #404 | `3568967d6` | xtree: enable the POSIX binary-tree variant (O(log n)) where available (TBT 61) |
| #406 | `d81407cd3` | xymond_rrd: size the rrd_create argv by what was filled in |
| #409 | `a891fd2b3` | install-tools: install the diagnostics the build discards, under xymon names |
| #410 | `bd907c98e` | build: install the libraries and headers with make install-devel |
| #411 | `9ed322ce8` | build: let the client's install directories be set, as the server's can |
| #414 | `ec10fb559` | build: install the shipped web content apart from what xymongen writes (TBT 1/2) |
| #425 | `0463dd938` | xymond: accept alternative df column names |
| #426 | `26aa32176` | client: write the shared filesystem code once, stamp it into the clients |
| #428 | `f7ff3d53a` | xymond: bind the address --listen names, not every interface |
| #432 | `f0ff0383b` | xymond: listen on several addresses, and keep a loopback among them |
| #435 | `d5df94654` | xymonserver.cfg: send over loopback, identify by the real address |
| #443 | `857c6ca64` | xymonserver.cfg: let rep and snap move together, under XYMONCACHEWWWDIR |
| #453 | `944644300` | xymonnet: wait for the direction SSL_connect asked for, not for writability |
| #454 | `5d0971e74` | xymonnet: retry a write that SSL_write() did not accept, instead of dropping it |
| #458 | `fbc855ca7` | xymonnet: an https test always sends the URL's host as SNI |
| #488 | `7671cd449` | xymonnet: a probe holds its conversation, and can upgrade to TLS |
| #495 | `1ef40a020` | xymond: a connection that broke is not a message that ended |
| #508 | `c6c3d5d34` | trimhistory: stop --drop deleting the history of hosts that are still listed (#281) |
| #509 | `d42d72a24` | lib/sendmsg: sending to nobody is not a successful send (#507) |
| #513 | `f400bcc7b` | trimhistory: refuse to drop on a hosts.cfg that lost an include (#512) |
| #514 | `99c25bdac` | tests/rrd: pin that the external processor stream is buffered by default |
| #531 | `d60346ee3` | xymond: build the notify channel message in a strbuffer, not a sized buffer |
| #532 | `b564263f8` | loadalerts: fire a PAGE= alert rule only when it matched the page |
| #548 | `e57d2ff79` | webaccess: let a group grant access to the top-level page |
| #549 | `f1fc33234` | client_config: read every page a host is on when deciding its ruleset |
| #552 | `297ccf5d4` | pagepath_matchname: call the helper where the link allows it |
| #564 | `92ee9502d` | xymond: say a hostname with a comma is not monitored, not that it is |
| #579 | `85d1de92d` | xymond: release the channels already set up when a later one fails |
| #581 | `5ad8b30a3` | xymond_locator.8: document the service locator |
| #582 | `7c321a715` | xymond_locator: keep running when a HUP interrupts its wait |
| #583 | `9c5ac8df3` | docs: name the locator options in the pages of the programs that take them |
| #584 | `3fa95d230` | xymon.7: list xymond_locator among the server tools |
| #585 | `d2db0e341` | stackio: keep NULs out of the include lines stackfgets() returns |
| #586 | `5d21deb1c` | svcstatus: link saved client data on the server the locator names |
| #587 | `f2e92eb60` | xymond_channel: give each peer its own copy of a broadcast message |
| #588 | `fcd907e3a` | xymond_channel: deliver messages sent while a network worker restarts |
| #589 | `1ac62dcef` | xymond_locator: return a server's extras whole |
| #598 | `226fd1d40` | xymond: give an empty ext/ to XYMONUSER without failing the install |
| #608 | `39a8d306a` | xtree: destroy a tree without reading keys its caller already freed |
