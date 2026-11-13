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
    - `/usr/libexec/xymon/server/bin`
    - `/usr/libexec/xymon/server/ext`
    - `/var/lib/xymon/tmp`
    - `/var/lib/xymon/www`
    - `/usr/share/man`

- `bsd_local`
  - Split layout following BSD localbase conventions for third-party software.
  - The localbase defaults to `CMAKE_INSTALL_PREFIX` (`/usr/local` in the
    checked-in preset) and the state root defaults to `/var`.
  - Example paths:
    - `/usr/local/etc/xymon`
    - `/usr/local/libexec/xymon/server/bin`
    - `/usr/local/libexec/xymon/server/ext`
    - `/usr/local/share/xymon/www`
    - `/var/xymon`

- `macos_tree`
  - Historical macOS layout rooted under `/Library/WebServer`.
  - Example paths:
    - `/Library/WebServer/server/bin`
    - `/Library/WebServer/client/bin`
    - `/Library/WebServer/cgi-bin`
    - `/Library/WebServer/cgi-secure`

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

The repo now has an explicit CMake layout selector and still supports the older
knobs that map onto it.

### CMake

- `XYMON_LAYOUT=home_tree|var_tree|bsd_local|macos_tree|fhs`
  - first-class layout selector
  - source: [CMakeLists.txt](/home/bc/repos/github/bonomani/xymon/CMakeLists.txt#L77)

- `USE_GNUINSTALLDIRS=ON`
  - maps to `fhs`

- `USE_GNUINSTALLDIRS=OFF`
  - now maps by platform default:
    - Linux -> `var_tree`
    - FreeBSD/NetBSD -> `home_tree`

- current default path sets:
  - `var_tree`
    - `XYMONTOPDIR=/var/lib/xymon`
    - `XYMONHOME=/var/lib/xymon/server`
    - `XYMONCLIENTHOME=/var/lib/xymon/client`
    - `CGIDIR=/var/lib/xymon/cgi-bin`
    - `SECURECGIDIR=/var/lib/xymon/cgi-secure`
  - `home_tree`
    - `XYMONTOPDIR=/home/_www`
    - `XYMONHOME=/home/_www/server`
    - `XYMONCLIENTHOME=/home/_www/client`
    - `CGIDIR=/home/_www/cgi-bin`
    - `SECURECGIDIR=/home/_www/cgi-secure`
  - `fhs`
    - default configured prefix: `/usr`
    - `XYMONTOPDIR=<prefix>/libexec/xymon`
    - `XYMONHOME=<prefix>/libexec/xymon/server`
    - `XYMONCLIENTHOME=<prefix>/libexec/xymon/client`
    - `INSTALLETCDIR=/etc/xymon`
    - `INSTALLWWWDIR=/var/lib/xymon/www`
    - `MANDIR=<prefix>/share/man`
    - install-time relocation with `cmake --install --prefix /opt/xymon`
      resolves runtime paths under `/opt/xymon/...`
  - `bsd_local`
    - `XYMON_BSD_LOCALBASE=<prefix>` (default from `CMAKE_INSTALL_PREFIX`)
    - `XYMON_BSD_LOCALSTATEDIR=/var` by default
    - `XYMONTOPDIR=<prefix>/libexec/xymon`
    - `XYMONHOME=<prefix>/libexec/xymon/server`
    - `XYMONCLIENTHOME=<prefix>/libexec/xymon/client`
    - `INSTALLETCDIR=<prefix>/etc/xymon`
    - `INSTALLWWWDIR=<prefix>/share/xymon/www`
    - `XYMONVAR=<state-root>/xymon`
  - `macos_tree`
    - `XYMONTOPDIR=/Library/WebServer`
    - `XYMONHOME=/Library/WebServer/server`
    - `XYMONCLIENTHOME=/Library/WebServer/client`
    - `INSTALLETCDIR=/Library/WebServer/server/etc`
    - `INSTALLWWWDIR=/Library/WebServer/server/www`
    - `XYMONVAR=/Library/WebServer/data`

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

- CI CMake configure helpers
  - `default` preset maps explicitly to:
    - FreeBSD/NetBSD -> `home_tree`
    - macOS -> `macos_tree`
    - other current platforms -> `var_tree`
  - `gnuinstall` and `packaging` map to `fhs`
  - `bsdlocal` and `macostree` remain available as explicit opt-in presets

- current FreeBSD and NetBSD checked-in make refs
  - use `home_tree`
  - example baseline root in CI compare logs and refs: `/home/_www`

- current macOS checked-in make refs
  - use the historical `/Library/WebServer` layout
  - terminology target for that shape: `macos_tree`
  - current macOS CMake default selection must also model this as `macos_tree`

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

The layout model is now explicit. The next cleanup step is naming:

- keep `home_tree`, `var_tree`, and `fhs` as the filesystem-shape terms
- gradually replace vague `legacy` wording where it actually means one of:
  - `make` parity
  - `ref` staging/compare
  - a specific layout
