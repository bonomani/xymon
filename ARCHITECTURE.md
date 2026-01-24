ARCHITECTURE.md
===============

No reverse dependency is allowed.


xymon_common Library
-------------------

### Role

`xymon_common` contains:
- generic utilities,
- shared client/server code,
- functionality independent of server mode.

It must **never** depend on server-specific code.

### Current Scope (B6.5 baseline)

- memory, string, time, and hash utilities
- generic data structures
- shared IPC and buffer handling
- low-level helpers reusable by client and server

### Files (B6.5)

- errormsg.c
- tree.c
- memory.c
- md5.c
- strfunc.c
- timefunc.c
- digest.c
- encoding.c
- calc.c
- misc.c
- msort.c
- files.c
- stackio.c
- sig.c
- suid.c
- xymond_buffer.c
- xymond_ipc.c
- matching.c
- timing.c
- crondate.c

### Explicit Exclusions

- no server business logic
- no server networking
- no configuration loaders
- no ownership of server data structures

### Constraints

- stable and reusable API
- suitable for client and server builds
- must remain dependency-clean


xymon_server_loaders Library
----------------------------

### Role

`xymon_server_loaders` contains:
- server-side configuration loaders isolated from server core,
- code with no runtime networking,
- modules eligible for extraction from server core.

It may depend on `xymon_common`.  
It must **not** depend on `xymon_server_core`.

### Current Scope (B6.7)

- loadalerts.c (wrapper)

The canonical implementation remains in:
- lib/loadalerts.c

The version located in `xymon_server_loaders` is a **build-level wrapper only**
used to support CMake-based isolation while preserving the historical
Autotools / Makefile build.

### Constraints

- no reverse dependency
- no runtime protocol handling
- no persistent writes
- explicit linkage from server core only
- wrapper files must not contain logic


xymon_server_core Library
------------------------

### Role

`xymon_server_core` contains:
- Xymon server-specific code,
- modules requiring server execution context,
- server-owned behavior.

It may depend on `xymon_common` and `xymon_server_loaders`.

### Current Scope (B6.7)

- server bootstrap / stub
- server logging logic
- non-extractable server configuration loaders

### Files

- server_stub.c

**Logs**
- eventlog.c
- notifylog.c
- htmllog.c
- reportlog.c

**Configuration loaders (server-scoped, non-extractable)**
- loadcriticalconf.c
- loadhosts.c

### Loader analysis references

- loadhosts.c
  → docs/architecture/loaders/loadhosts.md
- loadalerts.c
  → docs/architecture/loaders/loadalerts.md
- loadcriticalconf.c
  → docs/architecture/loaders/loadcriticalconf.md

### Loader Migration Status

- loadhosts.c  
  Classification: NON-EXTRACTABLE  
  Reasons:
  - direct inclusion of .c submodules
  - reliance on server-global mutable state
  - indirect network access via loader components

- loadalerts.c  
  Classification: ISOLATED VIA WRAPPER (B6.7)  
  Notes:
  - canonical source remains in lib/loadalerts.c
  - wrapper located in xymon_server_loaders
  - depends on xymon_common and libpcre
  - no network access
  - no persistent writes

- loadcriticalconf.c  
  Classification: NON-EXTRACTABLE  
  Reasons:
  - persistent configuration writes
  - clone and alias management
  - shared global configuration state

### Explicit Exclusions

- network protocol handling
- runtime daemon logic
- client-side behavior
- cross-mode shared ownership of server data

### Evolution Rules

- any migration into or out of server core must be:
  - explicit,
  - documented,
  - dependency-complete,
  - reversible.
- partial or speculative moves are forbidden.
- failed migrations must be reverted immediately.


xymond_channel Binary
--------------------

### Role

`xymond_channel` is a **minimal validation binary**.

It is used to:
- verify correct linkage,
- validate dependency consistency,
- serve as a CI anchor.

### Constraints

- no business logic
- no functional behavior
- internal use only (test / CI)


Global Architecture Rules
------------------------

- strictly unidirectional dependencies
- `xymon_common` must never include server semantics
- `xymon_server_core` owns server-only behavior
- extracted loaders must not reintroduce coupling
- all changes must:
  - keep the build green,
  - be atomic,
  - be architecture-compliant


Status
------

- Architecture baseline: **B6.5**
- Loader analysis completed: **B6.6**
- Loader isolation completed via wrapper: **B6.7**
- Architecture state validated by CI
- This document reflects the **current enforced structure**

