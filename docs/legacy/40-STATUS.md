RUN RESUME - POINTS IMPORTANTS

1) Cause racine des erreurs initiales
- "chgrp nobody" echoue car le groupe "nobody" n'existe pas (selon distro).
- "chown" echoue en mode non-root (Operation not permitted).
- "cmake --build ... -D..." est invalide: les -D se passent a "cmake -S/-B" (configure), pas a "cmake --build" (build).
- DESTDIR doit etre passe comme variable d'environnement ou Make (ex: `DESTDIR=/tmp/legacy-ref make install` ou `env DESTDIR=/tmp/legacy-ref make install`), pas en argument separé.

2) Correctif CMake applique
- Ajout d'un switch CMake: LEGACY_APPLY_OWNERSHIP (ON/OFF)
  - OFF: aucune operation chown/chgrp (mode staging/packaging utilisateur).
  - ON: chown/chgrp executes (mode installation root).
- install-legacy-dirs: creation des repertoires legacy.
- install-legacy-files: copie des fichiers web + chmod (et ownership seulement si LEGACY_APPLY_OWNERSHIP=ON).
- install-legacy-files invoque maintenant `cmake --install` pour prendre en charge les binaires, CGIs et composants client non-web.
- Copie conditionnelle des repertoires web (EXISTS) pour eviter les erreurs si un dossier manque.

3) Commandes validées (OK)

A) Staging / packaging (sans privileges)
 - configure:
   cmake -S . -B build-cmake -DLEGACY_APPLY_OWNERSHIP=OFF
 - prepare destdir:
   rm -rf dist-legacy && mkdir dist-legacy
 - build target:
   cmake --build build-cmake --target install-legacy-files

B) Installation reelle (avec privileges)
 - configure:
   cmake -S . -B build-cmake -DLEGACY_APPLY_OWNERSHIP=ON
 - build target en root (requires interactive sudo password):
   sudo cmake --build build-cmake --target install-legacy-files

4) Diff parité (OK)
 - `sudo make install DESTDIR=/tmp/legacy-ref` (reference tree lives under `/tmp/var/lib/xymon`; collected with `find /tmp/var/lib/xymon … | sed 's|/tmp||' | sort > legacy.ref`)
 - `cmake --build build-cmake --target install-legacy-dirs`/`install-legacy-files` with `LEGACY_DESTDIR=/tmp/cmake-ref-root` (staging under `/tmp/cmake-ref-root`; normalized tree via `find /tmp/cmake-ref-root/var/lib/xymon … | sed 's|/tmp/cmake-ref-root||' | sort > cmake.ref`)
 - `diff -u legacy.ref cmake.ref` now compares identical path roots.
 - `cmake.ref` was regenerated after the clean ON-mode install; rerunning the diff now only highlights the documented extra helper binaries and the optional staging log file.
 - Latest ON-mode install succeeded: the inline hook logged `Legacy hook: existing perms before change 755|xymon|xymon` and `Legacy hook: perms after change 4755|root|bc`, closing the `xymonping` SUID/group parity gap.
 - Key divergences needing justification:
   * Extra helper binaries (e.g., `availability`, `contest`, `loadhosts`, `locator`, `md5`, `rmd160`, `sha1`, `stackio`, `tree`, `xymon-snmpcollect`) appear only in the CMake tree and are now documented as intentional extras.
   * If `tee` is used during staging, `/var/lib/xymon/install-cmake-legacy.log` appears in the diff; treat it as a non-product artifact (exclude from parity checks or avoid `tee` when generating the list).
   * The new `install-legacy-files` hook now chowns `root:bc`, logs the stat snapshots before/after the change, and then chmods `4755`; the latest run confirms the final `4755 root:bc` state.
 - Ces points sont documentes dans le plan de validation (criteres OK).

5) Install modes et portabilité (OK)
 - `LEGACY_APPLY_OWNERSHIP=OFF cmake --build build-cmake --target install-legacy-files` completes with no chown/chgrp, and the same `Up-to-date` log appears even when `XYMONUSER` or `HTTPDGID` are unset (`env -u XYMONUSER ...`, `env -u HTTPDGID ...`), showing the install path is resilient when those variables are absent.
 - `find /tmp/cmake-ref-root/var/lib/xymon/cgi-bin -type f ! -perm 755` ne retourne rien (OK).
 - `find /tmp/cmake-ref-root/var/lib/xymon -perm 777` ne retourne rien d'inattendu (OK).
 - `test -d /tmp/cmake-ref-root/var/lib/xymon/server/www/help`, `.../menu`, et `stat .../www | grep '755'` passent (OK).
 - DESTDIR packaging: `cmake -S . -B build-cmake-destdir -DUSE_GNUINSTALLDIRS=OFF -DCMAKE_INSTALL_PREFIX=/ -DLEGACY_DESTDIR=/tmp/pkg`, followed by `cmake --build build-cmake-destdir` (to generate binaries) and `cmake --build build-cmake-destdir --target install-legacy-files`, succeeds and writes to `/tmp/pkg`; the first install attempt failed until the build artifacts existed.
 - After deleting `/tmp/cmake-ref-root` and rerunning the ON-mode install from scratch, `stat -c '%n|%U|%G|%a' /tmp/cmake-ref-root/var/lib/xymon/server/bin/xymonping` now shows `4755|root|bc`; the inline hook runs after the recursive `chown -R` and re-applies `chown root:bc` + `chmod 4755`.

6) Resultat
 - OFF: install-legacy-files termine sans erreur (pas de chown) including the edge-case runs above.
 - ON + sudo: command runs successfully and the inline hook confirms `4755 root:bc` for `xymonping`.

7) Point de vigilance restant
 - Le mapping HTTPDGID/rep/snap doit rester conditionnel (HTTPDGID defini + groupe existant) si tu veux eviter les erreurs "invalid group".
