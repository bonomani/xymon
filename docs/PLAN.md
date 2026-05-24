# PLAN

## CI — profil de dépendances macOS dédié (`macos_default`)

Fait : macOS ne réutilise plus le profil `linux_default`. Nouveau profil
`macos_default` (deps-base.yaml + deps-overlays.yaml) mappé dans
deps-targets.yaml. Il **n'inclut plus `TIRPC`** (pas de port `libtirpc` dans
MacPorts ; RPC/XDR fournis par le SDK macOS).

Contexte : la boucle d'install (`ci/deps/lib/install-common.sh`) est fail-fast.
`TIRPC→port:[libtirpc]` échouait et arrêtait l'install avant `pcre2`, faisant
échouer `configure` (PCRE requis) sur les lanes macOS **server** et
**localclient** ; seul **client** (CLIENTONLY, sans PCRE) passait.

Reste à vérifier (au prochain run macOS server) :
- le build serveur macOS compile sans paquet RPC/XDR (XDR attendu depuis
  `/usr/include/rpc` du SDK). Si non : trouver l'équivalent macOS plutôt que de
  réintroduire `libtirpc`.
