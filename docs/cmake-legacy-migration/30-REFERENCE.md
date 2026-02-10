Xymon - Legacy Installation Reference
=====================================
Installation contract derived from the legacy "configure + make" build system

1. Purpose

This document defines the authoritative legacy installation layout for Xymon,
as implemented by the existing Makefiles (not Autotools).

It is the normative reference for validating the CMake migration in
Legacy mode (USE_GNUINSTALLDIRS=OFF).

No interpretation, cleanup, or modernization is applied.

------------------------------------------------------------

2. Context and constraints

- Legacy build system:
  - Custom configure script
  - Custom Makefile logic
- Not supported:
  - --prefix
  - DESTDIR
- Installation paths are:
  - Absolute
  - Hardcoded
- make install:
  - Requires root privileges
- The target "install-dirs" is the single source of truth

------------------------------------------------------------

3. Normative source

All paths in this document are extracted exclusively from:

  build/Makefile.rules : install-dirs

No other targets or scripts are considered authoritative.

------------------------------------------------------------

4. Legacy variable values (effective)

XYMONHOME      = /var/lib/xymon/server
XYMONVAR       = /var/lib/xymon/data
INSTALLBINDIR  = /var/lib/xymon/server/bin
INSTALLETCDIR  = /var/lib/xymon/server/etc
INSTALLEXTDIR  = /var/lib/xymon/server/ext
INSTALLTMPDIR  = /var/lib/xymon/server/tmp
INSTALLWEBDIR  = /var/lib/xymon/server/web
INSTALLWWWDIR  = /var/lib/xymon/server/www

------------------------------------------------------------

5. Directory layout (canonical contract)

5.1 Xymon server root

/var/lib/xymon/server
/var/lib/xymon/server/download

------------------------------------------------------------

5.2 Binaries

/var/lib/xymon/server/bin

Symbolic link (if paths differ):
/var/lib/xymon/server/bin -> INSTALLBINDIR

------------------------------------------------------------

5.3 Configuration

/var/lib/xymon/server/etc

Symbolic link:
/var/lib/xymon/server/etc -> INSTALLETCDIR

------------------------------------------------------------

5.4 Extensions

/var/lib/xymon/server/ext

Symbolic link:
/var/lib/xymon/server/ext -> INSTALLEXTDIR

------------------------------------------------------------

5.5 Temporary files

/var/lib/xymon/server/tmp

Symbolic link:
/var/lib/xymon/server/tmp -> INSTALLTMPDIR

------------------------------------------------------------

5.6 Internal web (CGI, scripts)

/var/lib/xymon/server/web

Symbolic link:
/var/lib/xymon/server/web -> INSTALLWEBDIR

------------------------------------------------------------

5.7 Public web (WWW)

/var/lib/xymon/server/www
/var/lib/xymon/server/www/gifs
/var/lib/xymon/server/www/help
/var/lib/xymon/server/www/html
/var/lib/xymon/server/www/menu
/var/lib/xymon/server/www/notes
/var/lib/xymon/server/www/rep
/var/lib/xymon/server/www/snap
/var/lib/xymon/server/www/wml

Symbolic link:
/var/lib/xymon/server/www -> INSTALLWWWDIR

------------------------------------------------------------

5.8 Runtime data

/var/lib/xymon/data
/var/lib/xymon/data/acks

------------------------------------------------------------

6. Ownership and permissions (legacy behavior)

When PKGBUILD is not defined:

- Owner: $(XYMONUSER)
- Group: primary group of $(XYMONUSER)
- Permissions:
  - Directories: 755
  - Exceptions:
    /var/lib/xymon/server/www/rep
    /var/lib/xymon/server/www/snap
    -> group writable (g+w)
- If HTTPDGID is defined:
  - Group ownership of rep and snap is set to HTTPDGID

------------------------------------------------------------

7. Symbolic links (conditional)

Symbolic links are created only if the target directory differs:

$(XYMONHOME)/bin  -> $(INSTALLBINDIR)
$(XYMONHOME)/etc  -> $(INSTALLETCDIR)
$(XYMONHOME)/ext  -> $(INSTALLEXTDIR)
$(XYMONHOME)/tmp  -> $(INSTALLTMPDIR)
$(XYMONHOME)/web  -> $(INSTALLWEBDIR)
$(XYMONHOME)/www  -> $(INSTALLWWWDIR)

------------------------------------------------------------

8. CMake validation rules (Legacy mode)

For CMake Legacy mode to be considered compliant:

1. All directories listed above must be created
2. No additional directories are allowed
3. Symbolic links must follow the same conditions
4. All paths must be identical
5. USE_GNUINSTALLDIRS=OFF must be the only controlling switch

------------------------------------------------------------

9. Fundamental rule

This document is the normative reference.
Any deviation on the CMake side is a regression.
Any deviation on the legacy side is out of scope.

Note on DESTDIR:
- Legacy Makefiles do not officially support DESTDIR.
- In practice, when DESTDIR is set, the install currently lands under
  `/tmp/var/lib/xymon` (observed behavior used only for staging comparisons).

------------------------------------------------------------

10. Change policy

- Update this document only if `build/Makefile.rules` changes.
- Record updates in `STATUS-HISTORY.md` and refresh `40-STATUS.md`.
- The canonical legacy reference list used by CI is
  `docs/cmake-legacy-migration/refs/make_linux/server/ref`.

------------------------------------------------------------

11. Status

Status: Frozen legacy reference
Source: build/Makefile.rules
Usage: CMake migration and parity validation
Evolution: None, unless the legacy system itself changes
