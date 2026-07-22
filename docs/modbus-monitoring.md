# Monitoring Modbus à grande échelle avec Xymon

Design pour la supervision de milliers de compteurs Modbus, lus intégralement
chaque minute, derrière des gateways Modbus/TCP → RS-485. Aucune modification
du cœur de Xymon : tout passe par le mécanisme d'extension standard
(démon poller + messages `status`/`data`).

## 1. Contexte et contraintes

- Des milliers de compteurs sur des bus série RS-485, atteints via des
  gateways Modbus/TCP. L'adressage se fait par **unit ID** (slave ID) ;
  la gateway route vers le bus série.
- **Lecture exhaustive** : chaque compteur, tous ses registres, à chaque cycle.
- **Cycle : 1 minute.**
- Carte de registres par compteur : réduite (quelques dizaines de registres
  au plus), parfois contiguë, parfois éparse.

La contrainte dure n'est pas Xymon : c'est le **temps de bus série**.
Tout le dimensionnement en découle.

## 2. La physique du bus série

Sur un bus RS-485, une transaction Modbus coûte :

```
t_requête ≈ transmission (trame aller + retour) + latence équipement
          ≈ 200–250 ms à 9600 bauds pour un bloc de ~60 registres
          ≈ 4 à 10× moins à 38400/115200 bauds
```

Le coût dominant est **la requête** (trame + retournement + latence),
pas les octets : un registre supplémentaire ≈ 2 ms à 9600 bauds.
Le bus ne supporte qu'une transaction à la fois : tout est séquentiel
par gateway.

### Plafond de slaves par gateway

```
slaves_max ≈ budget_cycle / (requêtes_par_compteur × t_requête)
```

Avec un budget de ~45 s (marge timeouts) sur un cycle de 60 s :

| Bus         | Requêtes/compteur | t_requête | Plafond ~   |
|-------------|-------------------|-----------|-------------|
| 9600 bauds  | 2                 | 250 ms    | 80–100      |
| 38400 bauds | 2                 | 65 ms     | 300–350     |

Si une gateway dépasse ce plafond, **aucun logiciel ne le rattrape** :
bus plus rapide, gateway supplémentaire, ou gateway à cache (§4) —
dans cet ordre de coût. À valider en phase d'infrastructure, pas en recette.

### Slaves morts

Un slave HS avec timeout 1 s consomme le budget de 4–5 slaves vivants
par tour. Obligatoire : un **backoff** — un slave en échec n'est re-tenté
qu'un tour sur N, et passe `red` sans bloquer le bus chaque minute.
(Dans le démon en mode direct, ou via le « fault handling » de la gateway
en mode cache.)

## 3. Planificateur de blocs (registres épars)

Les registres d'un compteur étant parfois épars, on minimise le nombre de
requêtes en lisant **à travers les trous** :

- Règle de fusion : fusionner deux groupes si
  `taille_du_trou × t_registre < coût_d'une_requête`
  → en pratique, fusionner tout trou **< ~20–30 registres**,
  dans la limite de 125 registres par lecture (plafond PDU, fonction 0x03).
- Algorithme : trier les adresses, balayer, couper quand le trou dépasse
  le seuil ou que le bloc atteint 125. Calculé **une fois au chargement
  de la config** (et sur SIGHUP), pas à chaque cycle.
- Résultat typique : **1 à 3 requêtes par compteur**.

### Tolérance aux trous : profil par modèle

Certains équipements répondent `ILLEGAL DATA ADDRESS` si la lecture couvre
une adresse non implémentée. D'où un profil par **modèle** (pas par instance) :

```
[SOCOMEC_E23]
  registers   = 100-104, 110-112, 130
  merge_holes = yes        # tolère la lecture des trous

[SCHNEIDER_IEM]
  registers   = 3059-3060, 3067-3068, 3109
  merge_holes = no         # exception sur adresse non mappée → blocs stricts
```

Robustesse : au premier contact d'un modèle inconnu, tenter une lecture
fusionnée ; si exception, retomber en blocs stricts et mémoriser.

### Décodage

Les registres sont des `uint16`. Les valeurs 32 bits (float IEEE, compteurs)
occupent 2 registres avec un ordre de mots **variable selon le fabricant** :
prévoir le format dans le profil du modèle
(libmodbus : `modbus_get_float_abcd()` et variantes).

## 4. Gateways à cache (table pré-pollée)

Certaines gateways (Moxa MGate en mode agent, Anybus, …) pollent
**elles-mêmes** le bus en continu et entretiennent une table image des
registres en RAM, lue en Modbus/TCP.

### Ce que ça change

| Aspect                    | Mode direct (transparent)        | Mode cache (agent)                     |
|---------------------------|----------------------------------|----------------------------------------|
| Coût d'une lecture démon  | 200–250 ms (attente bus série)   | 2–5 ms (RAM via LAN)                   |
| Ordonnanceur dans le démon| Obligatoire (budget 60 s)        | Inutile — quelques gros blocs TCP      |
| Slave mort                | Bloque le bus (backoff requis)   | Encaissé par la gateway                |
| Balayage complet du parc  | Contraint par le bus             | < 1 s pour 5000 compteurs              |
| Planif. de blocs          | Dans le démon                    | Dans la config gateway (liste de commandes) |

La physique du bus **reste** : elle devient le *cycle interne* de la gateway
et borne la **fraîcheur** des données, plus la capacité à les lire.

### Le cycle interne de la gateway

```
cycle ≈ Σ (requêtes_par_slave × t_requête)   sur tous les slaves du bus
```

Il n'est pas saisi directement : il **résulte** de la config. Leviers :

1. **Liste des commandes** (quelles lectures, quels blocs) — levier principal ;
2. **Intervalle par commande** — utile pour *ralentir* certaines lectures ;
   demander plus vite que le bus ne sert à rien :
   `cycle_réel = max(consigne, temps de bus physique)` ;
3. **Vitesse du bus** — seul réglage qui abaisse le plancher ;
4. **Timeout / retries / fault handling** — bornent l'inflation du cycle
   quand des slaves meurent.

Exigence « données < 1 min » ⇒ **cycle interne < ~45 s par gateway**,
soit le même plafond de slaves qu'en mode direct. Le cycle se **mesure**
(compteurs de diagnostic de la gateway, ou observation de la période de
rafraîchissement d'un registre qui bouge).

### Le piège : validité des données

On lit un cache : une valeur peut être **périmée sans que rien ne l'indique**
(slave mort → la table garde la dernière valeur, ou des zéros, selon le
firmware). Impératif : lire aussi les **registres d'état par slave** exposés
par la gateway (flags comm OK/KO, âge de la donnée) et les traiter comme la
vérité pour le statut : **flag KO → `red` même si la valeur cachée semble
normale**. Sans ça, le monitoring affiche du vert sur des équipements morts.

### Bilan

Le démon passe d'« ordonnanceur temps réel sous contrainte » à
« lecteur rapide + vérificateur de fraîcheur ». La complexité migre dans la
config des gateways et la gestion de la validité — échange presque toujours
gagnant à cette échelle, **si** les gateways le supportent (premier point à
vérifier dans la fiche technique).

## 5. Le démon poller

Un **démon C** lié à **libmodbus** (`libmodbus-dev`) et `libxymon.a` —
pas une tâche relancée toutes les minutes (coût de reconnexion, dérive) :

- une connexion TCP **persistante** par gateway, un thread par gateway ;
- slaves déroulés séquentiellement sur la connexion (`modbus_set_slave()`),
  gateways en parallèle ;
- polling **étalé** sur le cycle (pas de rafale au top de la minute) ;
- `modbus_read_registers()` par blocs planifiés (§3) ;
- timeouts par slave (2–5 s en direct — bus série lent), backoff sur les morts ;
- re-résolution de la config sur SIGHUP.

Réutilise l'existant du dépôt :

- `load_hostnames()` / `xmh_item()` (lib/loadhosts) pour lire `hosts.cfg`
  et les tags — pas de parsing maison ;
- `sendmessage()` (lib/sendmsg) en **combo** : 5000 status + 5000 data/min
  envoyés un par un = milliers de connexions TCP vers xymond ; en combo,
  quelques dizaines d'envois groupés par minute ;
- distinction des pannes : `errno` `ETIMEDOUT` = slave muet ;
  exception Modbus = équipement présent mais refuse.

## 6. Intégration Xymon

### hosts.cfg

Une entrée par compteur, IP de la gateway partagée, slave ID dans le tag.
**Généré depuis l'inventaire** (CSV/CMDB), jamais édité à la main :

```
192.168.1.50  gw1        # conn
192.168.1.50  capteur-a  # noconn modbus:192.168.1.50:3:SOCOMEC_E23
192.168.1.50  capteur-b  # noconn modbus:192.168.1.50:7:SCHNEIDER_IEM
```

- Chaque compteur = un hôte à part entière (statut, alertes, graphes),
  même IP partagée.
- `noconn` sur les compteurs : seule la gateway porte le ping.
- Le démon sélectionne ses cibles via le tag (`xymongrep 'modbus:*'`
  côté script ; `xmh_item()` côté C).
- Pages par site/gateway pour garder l'interface navigable.

### Statuts et alertes

- Gateway injoignable (TCP) → compteurs enfants en **`clear`**
  (pas d'alerte sur clear) + alerte unique sur la gateway.
  Sinon : une panne de gateway = tempête de notifications.
- Slave muet / flag cache KO → `red` sur ce compteur seul.
- **Hystérésis** sur les seuils (seuil d'entrée ≠ seuil de sortie) :
  des milliers de compteurs oscillant autour d'un seuil = churn
  d'historique et d'alertes.
- Si le statut d'un compteur n'est pas rafraîchi chaque minute,
  déclarer la validité dans le message (`status+15 host.modbus ...`)
  pour éviter le purple.
- Les alertes passent par `alerts.cfg` standard (colonne comme une autre).

### Métrologie (RRD)

- Messages `data` au format NCV ; dans `xymonserver.cfg` :

```
TEST2RRD="...,modbus=ncv"
GRAPHS="...,modbus"
NCV_modbus="Energie:DERIVE,Puissance:GAUGE"
```

- **Le pas RRD par défaut est 300 s** : à un cycle de 1 min, données
  moyennées 5:1. Pour archiver à la minute : définitions dédiées dans
  `rrddefinitions.cfg` avec `--step 60` et des RRA dimensionnés
  (60 s sur quelques jours, puis consolidation).
  À fixer **avant** la création des RRD (changer le step après coup
  impose de recréer les fichiers).
  Alternative si la minute ne sert qu'à la détection : garder step 300 s
  et n'envoyer `data` qu'un cycle sur cinq.
- **rrdcached obligatoire** : 5000 updates/min ≈ 83 écritures/s en IO
  aléatoire sans lui. Le dépôt fournit `rrdcachectl` ; xymond_rrd sait
  s'y connecter. Avec flush groupé, l'IO devient séquentielle.

### Coût en régime permanent (5000 compteurs, cycle 60 s)

| Poste                | Volume                     | Verdict                          |
|----------------------|----------------------------|----------------------------------|
| Bus série            | §2 — par gateway           | **Le mur** ; dimensionner d'abord|
| Messages xymond      | ~10 000/min en combo       | Quelques dizaines d'envois — OK  |
| RRD                  | ~83 updates/s              | OK **avec rrdcached uniquement** |
| xymond (5000 hôtes)  | dans son domaine de conception | OK                          |

## 7. Une seule source de vérité

Avec 50+ gateways, trois configs décrivent le même parc :
`hosts.cfg`, les profils de modèles du démon, et (en mode cache) la liste
de commandes de chaque gateway. **Toutes générées depuis le même
inventaire** (les MGate s'exportent/importent en fichier), sinon elles
divergent à la première évolution du parc.

## 8. Points à valider avant de construire

1. Fiche technique des gateways : mode cache/agent ? fault handling ?
   registres d'état par slave ? export de config ?
2. Topologie réelle : slaves par gateway et vitesse de bus vs plafonds du §2.
3. Cartes de registres par modèle de compteur + tolérance aux trous +
   ordre des mots 32 bits.
4. Besoin réel de la minute : métrologie, statut, ou les deux ?
   (statut à 5 min = churn divisé par 5).
5. Le cycle interne mesuré de chaque gateway une fois configurée (< 45 s).
