# Migration du moteur HTTP de xymonnet vers libcurl — étude détaillée

Statut : **étude / design** — aucun code écrit. Branche : `feature/libcurl-http`
(basée sur `upstream/main`, da60ba2d2).

## 1. Motivation

Le moteur HTTP actuel de xymonnet est entièrement artisanal : construction des
requêtes à la main (`httptest.c`), transport TCP + TLS dans une boucle
`select()` maison (`contest.c`), décodage HTTP manuel — chunked, 100-Continue —
dans un callback (`httptest.c:35-281`). Conséquences :

1. **HTTPS à travers un proxy ne fonctionne pas.** En mode proxy, le code
   envoie `GET <URL absolue>` en clair au proxy (`httptest.c:512,522`) et ne
   fait le TLS que selon le schéma du *proxy* (`httptest.c:694-696`). La
   méthode `CONNECT` (tunnel requis pour https-via-proxy) n'existe nulle part
   dans l'arbre (vérifié : zéro occurrence dans `xymonnet/` et `lib/url.c`).
2. **Proxy joint en TLS (`https://proxy`) impossible** : `contest.c` n'a
   qu'une couche SSL par socket (`sslrunning`/`ssldata` uniques,
   `contest.h:118-127`) ; le TLS-in-TLS exigerait une refonte de sa couche I/O.
3. **Code protocolaire sécurité-critique possédé en propre** : handshake TLS
   non-bloquant fait main (`contest.c:327-741`), parsing HTTP manuel, pas de
   HTTP/2, pas d'IPv6 (`tcptest_t.addr` est un `sockaddr_in`, `contest.h:86`).

libcurl résout l'intégralité de ces points (CONNECT automatique, TLS-in-TLS
depuis 7.52, auth proxy Basic/Digest/NTLM, chunked/100-Continue natifs,
HTTP/2, IPv6), avec une interface — **curl_multi** — conçue précisément pour
les boucles d'événements à milliers de transferts concurrents.

## 2. État des lieux : architecture du moteur actuel

### 2.1 Flux d'exécution (xymonnet.c)

```
xymonnet.c:2427   for (t...) add_http_test(t)          ← httptest.c:331
xymonnet.c:2430   do_tcp_tests(timeout, concurrency)   ← contest.c (boucle select)
xymonnet.c:2490   t->certinfo = testresult->tcptest->certinfo   (récolte certs)
xymonnet.c:2573   send_http_results(...)               ← httpresult.c:112
xymonnet.c:2574   send_content_results(...)            ← httpresult.c:416
xymonnet.c:2576   send_sslcert_status(h)               ← xymonnet.c:1976
```

### 2.2 Le contrat central : `http_data_t` (contest.h:161-191)

C'est la pièce maîtresse de la migration : **le reporting ne connaît que cette
structure**. Qui écrit quoi, qui lit quoi :

| Champ | Écrit par (actuel) | Lu par | Rôle |
|---|---|---|---|
| `url`, `weburl`, `parsestatus` | `add_http_test` (httptest.c:351-365) | httpresult.c partout | URL décodée + options du testspec |
| `headers`, `hdrlen` | callback data (httptest.c:178-187) | httpresult.c:144,216,300,363,464 | En-têtes de la réponse **finale** (100-Continue éliminés) |
| `output`, `outlen` | callback data (httptest.c:142-155) | httpresult.c:388,466-487,593-631 | Corps (seulement si content-check regex, sinon jeté) |
| `httpstatus` | final callback (httptest.c:304) | httpresult.c:148-151 etc. | Code HTTP, ou `-CONTEST_Exxx` si erreur transport (httptest.c:326) |
| `contenttype` | final callback (httptest.c:306-321) | httpresult.c:509 | Content-Type |
| `contentcheck`, `exp`, `digestctx`, `digest` | `add_http_test` (httptest.c:387-479) | httpresult.c:450-522 | Type de vérification de contenu + regex/hash compilés |
| `contstatus` | httptest.c:409/414/478 + httpresult | httpresult.c:454,542 | Pseudo-statut du content check |
| `tcptest->errcode` | contest.c | httpresult.c:183-202 | `CONTEST_ETIMEOUT/ENOCONN/EDNS/EIO/ESSL` (contest.h:78-83) |
| `tcptest->connres` | contest.c:1244 | httpresult.c:188 | errno du `connect()` (message d'erreur) |
| `tcptest->open` | contest.c:1245 | httpresult.c:206 | Connexion établie ? |
| `tcptest->totaltime` | contest.c | httpresult.c:306-308,369-371 | Durée totale (« Seconds: » du rapport) |
| `tcptest->certinfo/certexpires/certsubject/certissuer/certkeysz/mincipherbits` | contest.c (session SSL) | xymonnet.c:2490,1994-2038 | Colonne `sslcert` |
| `httpcolor`, `errorcause`, `faileddeps` | httpresult.c | httpresult.c | Interne reporting |

**Conclusion structurante** : si un nouveau transport remplit ces champs à
l'identique, `httpresult.c` (657 lignes de logique de reporting, couleurs,
badtest, dépendances, dialup, content checks) **ne change pas d'une ligne**.

### 2.3 Ce que fait `add_http_test` (httptest.c:331-708)

1. `decode_url()` → `weburl` (desturl, proxyurl, okcodes/badcodes, postdata,
   expdata, columnname, testtype…) — parsing dans `lib/url.c` (syntaxe proxy
   Big Brother : `lib/url.c:637-662`, option `--bb-proxy-syntax`
   xymonnet.c:2208).
2. Résolution DNS du proxy **ou** de la cible (httptest.c:368-385) via le
   résolveur c-ares de xymonnet ; respecte `testip` (l'IP de hosts.cfg est
   déjà dans `desturl->ip`).
3. Choix du content-check selon `testtype` (httptest.c:387-451) : PLAIN/HEAD/
   STATUS, CONTENT (fichier `$XYMONHOME/content/<host>.substring`), CONT
   (regex ou digest si `#`), NOCONT, POST/SOAP (+check), NOPOST/NOSOAP, TYPE.
   Compilation regex POSIX `REG_EXTENDED|REG_NOSUB` (httptest.c:474-475) ou
   init digest (httptest.c:459-465).
4. Options TLS par schemeopts d'URL (httptest.c:488-501) : versions SSLv2/v3,
   TLS1.0/1.1/1.2/1.3, ciphers high/medium, HTTP 1.0/1.1.
5. Construction **manuelle** de la requête : méthode (POST/HEAD/GET,
   httptest.c:508), URL absolue si proxy / relative sinon (:512,:522), Host
   (:528-536), POST avec `file:` (chargement fichier, :542-577),
   Content-Type (:579-586), User-Agent depuis tag `browser` (:596-603),
   en-têtes libres `XMH_HTTPHEADERS` (:607-611), auth Basic préemptive ou
   `CERT:` client-cert (:613-622), `Proxy-Authorization: Basic` (:623-627),
   cookies depuis `httpcookies.c` (:628-649), Pragma/Cache-control (:652-660),
   SOAPAction (:663-668).
6. `add_tcp_test()` vers l'IP du proxy s'il existe, sinon la cible
   (:685-700) ; SNI selon flags `XMH_FLAG_SNI`/`NOSNI` ou `--sni` global
   (:702-707).

### 2.4 Ce que fait le décodage de réponse (httptest.c:35-328)

- Machine à états **chunked** complète (états `contest.h:152-159`) — ~135
  lignes.
- Élimination des réponses `100 Continue` (httptest.c:211-232).
- Séparation headers/corps, extraction `Content-Length`/`Transfer-Encoding`.
- Aiguillage du corps : jeté (NONE/CONTENTTYPE), stocké (REGEX/NOREGEX),
  haché (DIGEST) — httptest.c:135-163.
- Final : extraction statut + Content-Type, mapping erreurs transport en
  pseudo-statuts négatifs (httptest.c:283-328).

Tout le §2.4 **disparaît** avec libcurl (dé-chunking et 100-Continue natifs).

## 3. Principe de la migration

> **Remplacer le transport, préserver le contrat.**

- Nouveau module `xymonnet/httpcurl.c` (+ `httpcurl.h`) : implémente
  `add_http_test()` et une passe `run_http_tests()` sur **curl_multi**,
  et remplit `http_data_t` + un `tcptest_t` minimal par requête.
- `httpresult.c` : **inchangé**.
- `httpcookies.c` : **inchangé** (voir §5.6).
- `contest.c` : **inchangé** — il continue de porter tous les tests TCP non
  HTTP (smtp, imap, ldap, bannières) et leur colonne sslcert.
- `httptest.c` : conservé tel quel comme moteur de repli (« legacy »)
  derrière `#ifdef` ; les étapes 1-4 du §2.3 (décodage URL, DNS, content
  checks, schemeopts) sont **communes** et seront factorisées dans un fichier
  partagé (`httpsetup.c`) pour éviter la duplication.
- Sélection : compile-time `HAVE_LIBCURL` + option runtime `--no-libcurl`
  (repli legacy pour diagnostic différentiel et plateformes sans libcurl).

Le `tcptest_t` « minimal » est nécessaire parce que le reporting lit
`req->tcptest->errcode/open/connres/totaltime` (httpresult.c:183-208,306) et
que la récolte de certificats lit `testresult->tcptest->certinfo`
(xymonnet.c:2490). Le moteur curl alloue un `tcptest_t` zéroisé par requête et
remplit uniquement ces champs — aucun socket dedans.

## 4. Table de correspondance exhaustive legacy → libcurl

| Fonctionnalité | Legacy (fichier:ligne) | libcurl | Note |
|---|---|---|---|
| Méthode GET/POST/HEAD | httptest.c:508 | défaut / `CURLOPT_POSTFIELDS` / `CURLOPT_NOBODY` | POST `file:` : garder le chargement fichier existant (:542-577) puis `CURLOPT_POSTFIELDSIZE` |
| HTTP 1.0/1.1 (schemeopt `10`/`11`) | :500-501 | `CURLOPT_HTTP_VERSION` (`_1_0`/`_1_1`) | Défaut 1.1, comme legacy. **Pas** de HTTP/2 en phase 1 (parité des headers affichés) |
| Host + port non standard | :528-536 | automatique | |
| Content-Type POST/SOAP | :579-586 | `CURLOPT_HTTPHEADER` | |
| User-Agent (tag `browser`) | :596-603 | `CURLOPT_USERAGENT` | Chaîne identique `Xymon xymonnet/<version>` par défaut |
| En-têtes libres (`XMH_HTTPHEADERS`) | :607-611 | `curl_slist` → `CURLOPT_HTTPHEADER` | |
| Auth Basic serveur | :613-622 | `CURLOPT_USERPWD` + `CURLOPT_HTTPAUTH=CURLAUTH_BASIC` | Basic **préemptif** chez legacy ; CURLAUTH_BASIC seul reproduit ce comportement |
| Cert client (`CERT:fichier`) | :614-616 | `CURLOPT_SSLCERT` | |
| Proxy http, cible http | :512,:694 | `CURLOPT_PROXY` | GET absolu généré par curl — parité |
| Proxy http, cible **https** | **cassé** | automatique : tunnel `CONNECT` | **Bug résolu par construction** |
| Proxy **https** (TLS vers le proxy) | **impossible** | `CURLOPT_PROXY` avec `https://` | TLS-in-TLS natif (curl ≥ 7.52) |
| Auth proxy | :623-627 (Basic seulement) | `CURLOPT_PROXYUSERPWD` + `CURLOPT_PROXYAUTH` | Basic pour parité ; Digest/NTLM disponibles ensuite |
| Cookies (envoi) | :628-649 via httpcookies.c | assemblage `name=value; …` → `CURLOPT_COOKIE` | On garde la logique de matching host/path de httpcookies.c, seul le transport change |
| Cookies (récolte session) | httpresult.c:144 `update_session_cookies()` sur `req->headers` | inchangé | Fonctionne car notre header-callback remplit `headers` avec les `Set-Cookie:` |
| Pragma/Cache-control | :652-660 | `CURLOPT_HTTPHEADER` | Parité stricte des requêtes émises |
| SOAPAction | :663-668 | `CURLOPT_HTTPHEADER` | |
| Versions TLS (schemeopts `2/3/t/a/b/c/d`) | :488-495 | `CURLOPT_SSLVERSION` (`_SSLv2…_TLSv1_3`) | SSLv2/v3 : refusés par les libcurl modernes → erreur claire plutôt que silence |
| Ciphers high/medium (`h`/`m`) | :497-498, chaînes contest.c | `CURLOPT_SSL_CIPHER_LIST` | Réutiliser les chaînes `ciphershigh`/`ciphersmedium` existantes (contest.h:52-53) |
| SNI on/off (`XMH_FLAG_SNI`/`NOSNI`, `--sni`) | :702-707 | voir §5.8 | **Différence de comportement** — SNI-off nécessite un contournement |
| `testip` / IP pré-résolue | :368-385, connexion par IP + Host | `CURLOPT_RESOLVE` (`host:port:ip`) | Préserve la sémantique « tester l'IP de hosts.cfg, pas le DNS » |
| Échec DNS | parsestatus/EDNS (httpresult.c:189-195) | pré-vérif : si `ip == NULL` et résolveur en échec → EDNS sans lancer curl ; sinon `CURLE_COULDNT_RESOLVE_*` → EDNS | Les deux chemins convergent sur le même rapport |
| IP source (`--source-ip`, srcip par test) | via add_tcp_test | `CURLOPT_INTERFACE` | |
| Timeout global (`--timeout`) | do_tcp_tests | `CURLOPT_TIMEOUT` + `CURLOPT_CONNECTTIMEOUT` | Par transfert, ce que legacy approxime par test |
| Concurrence (`--concurrency`) | boucle select | `CURLMOPT_MAX_TOTAL_CONNECTIONS` (+ `MAX_HOST_CONNECTIONS=2` pour politesse) | |
| Redirections | **non suivies** (302/303/307 = verts, httpresult.c:47-49) | `CURLOPT_FOLLOWLOCATION = 0` | **Parité impérative** — suivre les redirects changerait la couleur de milliers de tests existants |
| 100-Continue | filtré (httptest.c:211-232) | curl ne livre que la réponse utile ; header-callback remet le buffer à zéro sur toute ligne `HTTP/` | Gère aussi les doubles jeux d'en-têtes |
| Chunked | machine à états :56-133 | natif (corps livré décodé) | ~135 lignes supprimées |
| Corps : stocker/hacher/jeter | :135-163 | write-callback identique (REGEX/NOREGEX → stocker ; DIGEST → `digest_data()` ; sinon jeter) | Réutilise `digest_init/data/done` de libxymon |
| Statut HTTP | sscanf headers (:304) | `CURLINFO_RESPONSE_CODE` | |
| Content-Type | parsing manuel (:306-321) | `CURLINFO_CONTENT_TYPE` | |
| Durée totale (« Seconds: ») | `tcptest->totaltime` | `CURLINFO_TOTAL_TIME_T` (µs) → `timespec` | |
| Durée connexion | `tcptest->duration` | `CURLINFO_CONNECT_TIME_T` (`APPCONNECT` pour inclure TLS) | |
| Erreurs transport | `CONTEST_E*` | table §5.4 | |
| Colonne sslcert | contest SSL session → xymonnet.c:1976-2044 | `CURLOPT_CERTINFO=1` + `CURLINFO_CERTINFO` | voir §5.5 — le point le plus délicat |

## 5. Résolution des problèmes, un par un

### 5.1 Proxy — les trois cas

- **http via proxy** : parité (GET absolu, Proxy-Authorization Basic).
- **https via proxy en clair** : curl émet `CONNECT cible:443`, tunnel, TLS
  de bout en bout. C'est le bug historique — résolu sans nouvelle syntaxe :
  la sémantique s'infère du schéma de la *cible*, déjà parsé
  (`lib/url.c:652-662`). Aucun changement de `hosts.cfg`.
- **https://proxy (TLS vers le proxy, ± TLS-in-TLS)** : supporté par curl.
  La syntaxe BB `http://proxy:port/https://cible/` accepte déjà un schéma
  sur la partie proxy — il suffit de le transmettre à `CURLOPT_PROXY`.

Aucune rétro-compatibilité à préserver sur https-via-proxy : le comportement
actuel est un échec systématique, personne ne peut en dépendre.

### 5.2 Redirections — piège de parité n°1

Legacy ne suit **jamais** les redirects et colorie 302/303/307 en vert, 301 en
jaune (httpresult.c:45-71). `CURLOPT_FOLLOWLOCATION` doit rester à 0, sinon la
sémantique de milliers de configs change silencieusement (un 302 vers une page
morte passerait de vert à rouge). Le suivi de redirects pourra devenir un
schemeopt *opt-in* ultérieur — hors périmètre de la migration.

### 5.3 En-têtes de réponse — piège de parité n°2

Le reporting affiche `req->headers` brut dans la page de statut
(httpresult.c:300-303) et y cherche les `Set-Cookie:`
(`update_session_cookies`, httpresult.c:144) ainsi que la ligne de statut pour
le message d'erreur (:216-230). Le header-callback curl doit donc reconstruire
un bloc d'en-têtes **identique au legacy** : ligne `HTTP/1.x NNN …` en tête,
en-têtes bruts, sans le corps ; remise à zéro du buffer à chaque nouvelle
ligne `HTTP/` (élimine 100-Continue et réponses du proxy au CONNECT — ces
dernières ne doivent **jamais** atteindre le reporting).

### 5.4 Mapping des erreurs `CURLE_*` → `CONTEST_E*`

Le reporting choisit son texte selon `tcptest->errcode` (httpresult.c:183-202)
et sa couleur selon `httpstatus` (négatif = erreur transport, httptest.c:326) :

| CURLcode | CONTEST_E* | Texte rapporté (existant) |
|---|---|---|
| `CURLE_OPERATION_TIMEDOUT` | `ETIMEOUT` | "Server timeout" |
| `CURLE_COULDNT_CONNECT` | `ENOCONN` + `connres` ← `CURLINFO_OS_ERRNO` | `strerror(connres)` |
| `CURLE_COULDNT_RESOLVE_HOST` / `_PROXY` | `EDNS` | "Hostname not in DNS" / "DNS error" |
| `CURLE_URL_MALFORMAT` | `EDNS` + `parsestatus=1` | "Invalid URL" |
| `CURLE_SSL_*`, `CURLE_PEER_FAILED_VERIFICATION` | `ESSL` | "SSL error" |
| `CURLE_SEND_ERROR` / `RECV_ERROR` / `PARTIAL_FILE` / `GOT_NOTHING` | `EIO` | "I/O error" |
| autres | `EIO` | "I/O error" ; texte curl (`curl_easy_strerror`) ajouté en détail dans le corps du statut |
| `CURLE_OK` | `ENOERROR`, `open=1` | — |

`open` = 1 dès que la connexion TCP a abouti (`CURLINFO_CONNECT_TIME_T > 0`),
pour préserver la distinction « Connect failed » (httpresult.c:206-208).

### 5.5 Colonne sslcert — le point le plus délicat

Aujourd'hui `send_sslcert_status()` (xymonnet.c:1976-2044) consomme, par test :
`certinfo` (texte subject+expiration), `certexpires` (`time_t`),
`certissuer`, `certkeysz`, `mincipherbits` — remplis par contest.c depuis la
session OpenSSL, et recopiés en xymonnet.c:2490.

Avec curl : `CURLOPT_CERTINFO` + `CURLINFO_CERTINFO` fournissent, par
certificat de la chaîne, des paires clé/valeur texte (`Subject`, `Issuer`,
`Expire date`, `Public Key Algorithm`…). Travail nécessaire :

- reconstruire `certinfo` au **même format texte** que contest (le format
  actuel est ce que les utilisateurs voient — parité visuelle) ;
- parser `Expire date` (format ASN.1 `MMM DD HH:MM:SS YYYY GMT`) → `certexpires` ;
- extraire la taille de clé → `certkeysz`.

**Perte fonctionnelle documentée** : `mincipherbits` et la liste des ciphers
supportés par le serveur (`--showallciphers`, `sslincludecipherlist`)
proviennent d'un *scan multi-connexions* fait par contest — curl ne fait
qu'une session et n'expose que le cipher négocié. Décision proposée : pour les
tests http, la section « ciphers supportés » de sslcert affiche uniquement le
cipher négocié (`CURLINFO_TLS_SSL_PTR` ou en-tête info) ; le scan complet
reste disponible via les services TCP (imaps, pop3s…) qui restent sur
contest. Alternative si jugé bloquant : conserver le scan de ciphers via une
passe contest dédiée aux seuls hosts avec `--showallciphers` (rare).

### 5.6 Cookies

Deux directions, deux mécanismes distincts chez legacy :

- **Envoi** : `httpcookies.c` charge le fichier de cookies et matche
  host/path (httptest.c:628-649). On garde exactement cette logique et on
  assemble la chaîne pour `CURLOPT_COOKIE`. On n'utilise **pas**
  `CURLOPT_COOKIEFILE` : le format du fichier xymon n'est pas Netscape, et le
  matching maison (tailmatch) est le comportement documenté.
- **Récolte** : `update_session_cookies()` lit `req->headers`
  (httpresult.c:144) — inchangé grâce au §5.3.

### 5.7 Tests « data » (apache) et content checks

- Le write-callback reproduit l'aiguillage legacy (httptest.c:136-163), avec
  une exception à vérifier en implémentation : les tests `senddata` (rapport
  apache, httpresult.c:379-396) lisent `req->output` alors que leur
  contentcheck peut être NONE — auditer le chemin legacy exact
  (`WEBTEST_APACHE` dans `lib/url.c`) et répliquer ; règle sûre :
  **si `t->senddata`, toujours stocker le corps**.
- Content checks (REGEX/NOREGEX/DIGEST/CONTENTTYPE) : la compilation
  (httptest.c:453-479) part dans le module commun, l'évaluation
  (httpresult.c:440-527) est inchangée. Le corps stocké n'est **pas** tronqué
  au transport (la troncature MAX_CONTENT_DATA n'intervient qu'à l'affichage,
  httpresult.c:598) — parité du matching sur corps complet.

### 5.8 SNI on/off — différence assumée

Legacy peut désactiver le SNI (`XMH_FLAG_NOSNI`, défaut `--sni=off` historique,
httptest.c:702-707). curl envoie toujours le SNI quand l'URL contient un nom.
Contournement fidèle pour `nosni` : passer l'URL à curl avec l'**IP** en hôte
et forcer `Host:` via `CURLOPT_HTTPHEADER` (pas de nom → pas de SNI), au prix
de la vérification du nom de certificat (`CURLOPT_SSL_VERIFYHOST=0` — legacy
ne vérifie de toute façon **pas** les certificats serveur : aucune
`SSL_CTX_set_verify` dans contest.c). À documenter dans le man `xymonnet.1` :
`nosni` devient un mode dégradé explicite.

**Note générale sur la vérification TLS** : legacy n'a jamais validé les
certificats (il les *collecte* pour sslcert, sans échouer sur auto-signé ou
expiré). Parité ⇒ `CURLOPT_SSL_VERIFYPEER=0, VERIFYHOST=0` par défaut.
L'activation de la vérification (comportement plus sain) est un changement de
sémantique à proposer séparément, en opt-in (schemeopt), jamais dans la
migration.

### 5.9 Résolution DNS et `testip`

xymonnet pré-résout via c-ares (file d'attente `dns.c`, y compris le proxy —
`dns.c:247-249`) et respecte `testip` (l'IP de hosts.cfg court-circuite le
DNS). Pour la parité : garder la pré-résolution telle quelle, et pincer le
résultat avec `CURLOPT_RESOLVE "host:port:ip"`. Bénéfices : sémantique
`testip` intacte, rapport EDNS *avant* transfert (comme aujourd'hui,
httptest.c:364-385), et pas de double résolution par curl.

### 5.10 Concurrence, timeout, équité

- `curl_multi_perform` + `curl_multi_wait` en boucle ; ajout des handles par
  paquets de `--concurrency` (parité de la charge émise).
- `CURLMOPT_MAX_TOTAL_CONNECTIONS = concurrency`.
- `CURLOPT_TIMEOUT = --timeout` par transfert. Legacy applique le timeout par
  test dans la boucle select — même granularité.
- `--shuffle` (contest.c) : mélanger la liste avant l'ajout des handles.
- Statistiques : incrémenter `tcp_stats_http` etc. (contest.h:193-198) pour
  que le récapitulatif `--report` reste correct.

### 5.11 Ce qui est volontairement hors périmètre de la phase 1

- HTTP/2, HTTP/3 (changerait le bloc d'en-têtes affiché) ;
- suivi de redirections opt-in ;
- vérification des certificats serveur (opt-in futur) ;
- migration des tests LDAP (ldaptest.c a le même genre de dette — chantier
  distinct) ;
- toute modification de contest.c.

## 6. Différences de comportement assumées (récapitulatif)

| # | Différence | Impact | Mitigation |
|---|---|---|---|
| 1 | https-via-proxy passe de « échec systématique » à « fonctionne » | Des tests éternellement rouges peuvent virer au vert | C'est le but ; note de release |
| 2 | Textes d'erreur transport plus précis (curl_easy_strerror en détail) | Cosmétique | Textes de 1er niveau inchangés (§5.4) |
| 3 | Ordre/casse des en-têtes de *requête* émis par curl ≠ legacy | Serveurs pathologiques uniquement | Aucune — non observable dans les rapports |
| 4 | `nosni` = connexion par IP sans vérif du nom | Hosts avec `nosni` explicite (rares) | Documentation man page |
| 5 | sslcert : plus de scan multi-ciphers pour les tests http | `--showallciphers` sur colonnes http | Cipher négocié affiché ; scan complet conservé sur services TCP |
| 6 | SSLv2/SSLv3 par schemeopt : erreur explicite au lieu d'un test | Configs testant du SSL antédiluvien | Message clair ; ces protocoles sont retirés des libssl modernes de toute façon |

## 7. Intégration au système de build

### 7.1 make (autoconf maison)

- `configure` : probe pkg-config `libcurl` (modèle : probes existants de
  `build/`) → variables `CURLFLAGS`/`CURLLIBS` + define `HAVE_LIBCURL` dans
  `include/config.h`. Options : `--with-libcurl[=path]` / `--without-libcurl`.
- `xymonnet/Makefile` : `NETTESTOBJS += httpcurl.o httpsetup.o` (le .o legacy
  `httptest.o` reste — repli runtime) ; règle de compilation avec
  `$(CURLFLAGS)` ; édition de liens avec `$(CURLLIBS)` (xymonnet/Makefile:32-33).
- Sans libcurl : `httpcurl.c` compile vide (`#ifndef HAVE_LIBCURL`), xymonnet
  se comporte exactement comme aujourd'hui. **Aucune plateforme n'est cassée.**

### 7.2 CMake (branche cmake/bootstrap)

`find_package(CURL)` + `target_link_libraries(xymonnet PRIVATE CURL::libcurl)`
conditionnel. La politique projet (make en fin de vie) s'applique : le make
reçoit le minimum fonctionnel, l'investissement propre va dans CMake.

### 7.3 Politique de dépendance

libcurl reste **optionnelle** au build (vieux unix), mais devient la voie par
défaut quand présente. Trajectoire : optionnelle (phase 1) → défaut avec
`--no-libcurl` de secours (phase 2, une release) → retrait du moteur legacy
HTTP (phase 3, décision de release majeure — RFC).

## 8. Stratégie de validation

### 8.1 Parité différentielle (l'outil principal)

Mode `--compare-http` : exécute chaque test http sur **les deux moteurs** et
imprime les divergences champ à champ (`httpstatus`, couleur calculée,
`contenttype`, longueur d'output, certexpires, erreur). C'est peu de code (les
deux moteurs remplissent la même structure) et c'est la seule preuve de
non-régression opposable sur un parc réel. À faire tourner sur les hosts.cfg
de test puis en pré-production sur un vrai parc.

### 8.2 Matrice de tests dirigés (environnement local : nginx + squid)

| Axe | Cas |
|---|---|
| Schémas | http, https, https+schemeopts (versions TLS, ciphers) |
| Méthodes | GET, HEAD, POST (inline, `file:`), SOAP |
| Statuts | 200, 301/302/307 (non-suivi !), 401, 404, 500, réponse vide, connexion refusée, timeout connect, timeout transfert, DNS inexistant |
| Corps | content-length, chunked, 100-Continue, > 1 Mo (troncature affichage), binaire |
| Checks | CONT regex ok/ko, NOCONT, digest md5/sha1/sha256, TYPE, okcodes/badcodes |
| Proxy | http-cible via squid, https-cible via squid (CONNECT), auth proxy ok/ko, proxy down, proxy DNS-inexistant, https://proxy si build curl le permet |
| Cookies | envoi depuis fichier, récolte Set-Cookie session |
| SSL | cert valide, expiré, auto-signé (ne doit PAS échouer — §5.8), colonne sslcert (dates, sujet, clé) |
| Divers | testip, srcip, dialup, badtest, deptest, senddata/apache, columnname dédié, hidehttp |
| Échelle | 500 URLs, `--concurrency` 5/50, `--shuffle`, mesure du temps de passe vs legacy |

### 8.3 Non-régression du reste

`contest.c` n'étant pas modifié, les services TCP purs n'ont besoin que d'un
smoke test (le lien et les globals partagés — `tcp_stats_*`, ciphers — sont
les seuls points de contact).

## 9. Découpage en livraisons

1. **PR-1 — factorisation** : extraire §2.3 étapes 1-4 vers `httpsetup.c`
   sans changement de comportement (pur déplacement, diff mécanique).
2. **PR-2 — moteur curl** : `httpcurl.c`, build optionnel, `--no-libcurl`,
   mode `--compare-http`. Le défaut reste legacy dans cette PR.
3. **PR-3 — bascule du défaut** : curl par défaut si compilé, notes de
   release (dont §6), man pages (`xymonnet.1` : proxy https, nosni).
4. **PR-4 (ultérieure, RFC)** : retrait du moteur legacy HTTP + de la machine
   chunked ; contest.c reste pour le TCP pur.

Estimation : PR-1 ~1 j ; PR-2 ~4-6 j dont la moitié sur sslcert (§5.5) et la
matrice §8.2 ; PR-3 ~1 j + validation terrain. Risque principal : écarts de
parité subtils sur des serveurs réels → c'est précisément ce que
`--compare-http` (§8.1) rend mesurable avant toute bascule.

## 10. Décisions ouvertes (à trancher avant PR-2)

1. sslcert/ciphers : l'option « cipher négocié seul » du §5.5 suffit-elle, ou
   faut-il préserver le scan pour les colonnes http ?
2. Version minimale de libcurl supportée (proposition : 7.52 — TLS-in-TLS —
   disponible partout depuis Debian 9 / RHEL 8 ; plus vieux ⇒ désactiver le
   cas https://proxy avec message).
3. Faut-il exposer dès la phase 1 un schemeopt « suivre les redirects » ?
   (proposition : non — périmètre minimal).
4. Calendrier vis-à-vis de la phase projet « absorption des patchs distro » :
   cette migration est un sujet de la phase *rethink* ; la présente étude fige
   l'analyse pour ne pas la refaire.
