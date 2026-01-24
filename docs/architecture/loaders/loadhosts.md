Module: loadhosts.c

Includes:
- <stdio.h>
- <string.h>
- <ctype.h>
- <stdlib.h>
- <time.h>
- <limits.h>
- libxymon.h
- loadhosts_file.c
- loadhosts_net.c

External symbols (selected):
- errprintf
- xfree
- newstrbuffer
- addtobuffer
- clearstrbuffer
- timestr2timet
- getcurrenttime
- nlencode
- xgetenv
- xtreeNew
- xtreeAdd
- xtreeFind
- xtreeDestroy
- xtreeData
- xtreeEnd
- load_hostnames
- load_hostinfo
- get_fqdn
- malloc
- calloc
- strdup
- snprintf
- strcasecmp
- strncasecmp

Data access:
- Structures: namelist_t, pagelist_t
- Builds and mutates server-global host and page lists
- Allocates and frees memory explicitly
- Constructs and destroys host trees (rbhosts, rbclients)

Runtime access:
- Network: indirect (via loadhosts_net.c)
- Sockets: indirect / unknown
- Server loop: no
- Daemon runtime: no

Coupling:
- Direct dependency on server-global state
- Direct inclusion of .c submodules
- Provides query and mutation APIs (knownhost, hostinfo, xmh_*)

Status:
- TRANSITIONAL (B6.5 -> B6.6)

