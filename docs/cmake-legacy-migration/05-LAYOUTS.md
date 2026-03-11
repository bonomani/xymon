Xymon Layout Taxonomy
=====================

Purpose
-------
This note defines the layout names to use during the migration work so that
"legacy" is no longer used as a catch-all term for unrelated concepts.

Use these names to describe filesystem shape only.

Layout Names
------------

- `home_tree`
  - One top-level home-like root containing server, client, CGI, and data.
  - Example root: `/home/_www`
  - Example paths:
    - `/home/_www/server/bin`
    - `/home/_www/client/bin`
    - `/home/_www/cgi-bin`
    - `/home/_www/data`

- `var_tree`
  - One top-level root under `/var/lib/xymon` containing server, client, CGI,
    and data.
  - Example root: `/var/lib/xymon`
  - Example paths:
    - `/var/lib/xymon/server/bin`
    - `/var/lib/xymon/client/bin`
    - `/var/lib/xymon/cgi-bin`
    - `/var/lib/xymon/data`

- `fhs`
  - Split layout following filesystem hierarchy style packaging.
  - Example paths:
    - `/etc/xymon`
    - `/usr/lib/xymon/server/bin`
    - `/usr/lib/xymon/server/ext`
    - `/var/lib/xymon/tmp`
    - `/var/lib/xymon/www`

What These Names Do Not Mean
----------------------------

- They do not mean `make` vs `cmake`.
- They do not mean `ref` vs `compare`.
- They do not mean "old" vs "new".

Use separate terms for those:

- build system: `make`, `cmake`
- validation mode: `ref`, `compare`
- layout: `home_tree`, `var_tree`, `fhs`

Current Knob Mapping
--------------------

The repo currently expresses these layouts indirectly through several older
knobs. This is the current mapping without changing code yet.

### CMake

- `USE_GNUINSTALLDIRS=ON`
  - means `fhs`

- `USE_GNUINSTALLDIRS=OFF`
  - currently means `var_tree`
  - source: [CMakeLists.txt](/home/bc/repos/github/bonomani/xymon/CMakeLists.txt#L78)
  - current hardcoded defaults:
    - `XYMONTOPDIR=/var/lib/xymon`
    - `XYMONHOME=/var/lib/xymon/server`
    - `XYMONCLIENTHOME=/var/lib/xymon/client`
    - `CGIDIR=/var/lib/xymon/cgi-bin`
    - `SECURECGIDIR=/var/lib/xymon/cgi-secure`

- current gap
  - there is no first-class `home_tree` selector in CMake today
  - FreeBSD parity lanes need this

### Legacy configure + make

- `configure.server` with no overrides
  - means "derive root from the install user's home directory"
  - in layout terms this is `home_tree`
  - source: [configure.server](/home/bc/repos/github/bonomani/xymon/configure.server#L206)

- `XYMONTOPDIR=/var/lib/xymon`
  - means `var_tree`

- Debian-style profile overrides
  - mean `fhs`
  - source: [ci/profiles/make-layouts.yml](/home/bc/repos/github/bonomani/xymon/ci/profiles/make-layouts.yml#L1)

### CI profiles and staging

- `ci/profiles/make-layouts.yml`
  - `default` profile maps to `var_tree`
  - `debian` profile maps to `fhs`

- current FreeBSD checked-in make refs
  - use `home_tree`
  - example baseline root in CI compare logs: `/home/_www`

Recommended Terminology
-----------------------

When describing a lane or contract, prefer statements like:

- `make + home_tree`
- `cmake + var_tree`
- `cmake + fhs`
- `compare make/home_tree against cmake/home_tree`

Avoid statements like:

- `legacy layout`
- `legacy dirs`
- `legacy mode`

unless the text is explicitly about historical Makefile behavior and cannot be
made more precise.

Next Step for Code
------------------

Before renaming variables, stabilize behavior around an explicit internal model:

- `home_tree`
- `var_tree`
- `fhs`

Then map old knobs onto that model and rename the old `legacy` terminology in a
separate cleanup.
