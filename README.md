# storage-lucien — Couche Stockage HA

Brique de stockage distribué et hautement disponible pour la plateforme
SecurePulse, conforme à l'architecture décrite dans le rapport annuel
(§39-41, §56) : chaque datacenter (DC) héberge **2 nœuds de stockage** en
réplication **synchrone** GlusterFS, exportés en NFS pour les serveurs de
mail du même DC. Entre les DC, la réplication est **asynchrone**
(géo-réplication GlusterFS), conformément au rapport.

Cette brique comble un gap identifié : le rapport décrit un unique "serveur
distant (dans le même DC)" pour le NFS, protégé par du RAID contre la panne
disque — mais pas contre la panne du serveur lui-même. `storage-lucien`
ajoute cette HA manquante avec **Pacemaker + Corosync + une VIP flottante**.

```
                     ┌─────────────── DC "site" ───────────────┐
  Mail (Postfix/     │   VIP flottante (Pacemaker/Corosync)     │
  Dovecot) ───NFSv4──┼──▶ storage-<site>-1 ◀══ sync ══▶ storage-<site>-2
                     │        (GlusterFS replica-2, NFS-Ganesha sur les 2)
                     └───────────────────┬───────────────────────┘
                                          │ géo-réplication GlusterFS (async)
                                          ▼
                              storage-<autre-site>-*
```

## Pourquoi seule la VIP est pilotée par Pacemaker

GlusterFS (replica-2) et NFS-Ganesha tournent **en permanence sur les deux
nœuds** d'un DC, démarrés directement par `entrypoint.sh` — pas par
Pacemaker. La cohérence des données est déjà garantie en continu par
GlusterFS ; Pacemaker n'a donc qu'une seule décision à prendre : quel nœud
(déjà prêt) reçoit le trafic client, via une VIP unique (`ocf:heartbeat:IPaddr2`).
C'est une bascule beaucoup plus simple et fiable, en conteneurs, que de faire
piloter par Pacemaker le montage FUSE et l'export NFS eux-mêmes (agents OCF
fragiles pour ce genre d'opération en environnement conteneurisé).

## Multi-maître via géo-réplication GlusterFS (bidirectionnelle)

La géo-réplication GlusterFS native est conçue pour un usage DR classique :
un volume primaire, un secondaire **en lecture seule**. Notre besoin est
différent — chaque DC doit accepter des écritures locales (un mail arrive
là où le client s'est connecté) qui se propagent ensuite de façon
asynchrone vers les autres DC : c'est du **multi-maître**, pas du DR
classique. Chaque site crée donc une session vers *chacun* des autres sites
(bidirectionnelle entre chaque paire), ce qui a pour conséquence que
`gluster ... create` marque automatiquement chaque volume "secondaire"
(donc, au final, tous les volumes) en lecture seule — cassant les écritures
locales. `entrypoint.sh` réaffirme `features.read-only off` sur son propre
volume à chaque cycle (`ensure_local_writable`, toutes les 30s) pour
contourner ce verrou de sécurité. Limite acceptée : en cas d'écriture
concurrente sur la *même* boîte mail depuis deux DC différents au même
moment, aucune résolution de conflit n'est effectuée (le rapport lui-même
ne traite pas ce cas).

## Limitations connues (documentées, pas des bugs)

- **Pas de vrai STONITH** : un cluster Pacemaker à 2 nœuds a normalement
  besoin d'un mécanisme de fencing matériel pour être totalement à l'abri du
  split-brain. Il n'existe pas d'équivalent réaliste en conteneurs Docker.
  Le cluster tourne avec `stonith-enabled=false` et s'appuie uniquement sur
  le quorum `two_node`/`wait_for_all` de Corosync. **Ne pas reproduire tel
  quel en production** — en prod, ajouter un vrai agent de fencing (IPMI,
  fence_vmware, etc.) ou un 3ᵉ nœud/witness.
- **Chiffrement Corosync désactivé** (`crypto_cipher: none`) pour simplifier
  la démo dans un réseau Docker isolé. En production, générer une clé avec
  `corosync-keygen` et activer `crypto_cipher: aes256`.
- **Trust SSH de géo-réplication** : chaque nœud génère sa propre paire de
  clés au premier démarrage et publie sa clé publique dans etcd
  (`/georep-keys/<site>/<hostname>`) ; tous les nœuds font confiance à toutes
  les clés publiées. Acceptable dans un réseau Docker fermé de simulation,
  **pas un modèle de confiance suffisant pour un vrai multi-site exposé**.
- **Montage NFSv4 cross-conteneur bloqué sur certains hôtes Docker** (constaté
  sur l'environnement de développement utilisé pour ce projet) : l'export NFS
  se charge et fonctionne correctement (confirmé en local, `mount 127.0.0.1:/`
  et `mount <IP propre>:/` réussissent), mais un montage depuis un **autre**
  conteneur échoue systématiquement avec `access denied by server` — reproduit
  à l'identique avec NFS-Ganesha (FSAL_GLUSTER) **et** avec le serveur NFS du
  noyau Linux (nfsd/mountd), sur plusieurs sous-réseaux Docker jamais utilisés
  auparavant, avec permissions d'export totalement ouvertes (`*`, IP cliente
  explicite, `no_root_squash`, `insecure`), après vérification exhaustive de
  la connectivité réseau (ping, connexion TCP brute, capture de session
  authentifiée) — donc **pas** un problème de configuration applicative de
  ce repo, mais une caractéristique du noyau/de la pile réseau Docker de cet
  hôte précis (probablement une interaction conntrack/netfilter avec le
  protocole RPC, hors de portée d'investigation sans accès root à l'hôte, et
  hors de portée de correction sans modifier l'hôte — explicitement exclu du
  périmètre de ce projet). Le code de montage (`entrypoint.sh` de ce repo et
  de `Mail/dovecot/`) suit les pratiques standard NFSv4 et devrait fonctionner
  normalement sur un hôte Docker sans cette particularité. Documenté ici pour
  transparence plutôt que masqué ; voir `Mail/CHANGELOG.md` pour le détail de
  l'investigation menée.
  ⚠️ Effet de bord découvert pendant l'investigation : monter le pseudo-
  système de fichiers `nfsd` (`mount -t nfsd nfsd /proc/fs/nfsd`, nécessaire
  uniquement pour tester le serveur NFS du **noyau** — non utilisé par
  storage-lucien qui reste sur NFS-Ganesha userspace) peut laisser le
  conteneur dans un état que `docker rm -f` ne peut plus nettoyer (namespace
  noyau bloqué). N'affecte pas storage-lucien en usage normal.

## Variables d'environnement

| Variable | Défaut | Rôle |
|---|---|---|
| `ETCD_URL` | `http://etcd:2379` | Backend de découverte (même etcd que DNS/LDAP/Mail/LB-Syo) |
| `SITE` | `local` | Nom du DC (doit être identique pour les 2 nœuds d'une paire) |
| `STORAGE_ID` | `1` | `1` ou `2` — identifiant du nœud dans sa paire |
| `STORAGE_VIP` | *(requis)* | IP flottante du DC, doit être libre dans le même /24 que le réseau du DC |
| `STORAGE_VIP_CIDR` | `24` | Masque appliqué à la VIP |

Le NIC à utiliser est **auto-détecté** (celui dont l'IP est dans le même /24
que `STORAGE_VIP`) — pas besoin de le spécifier, robuste même si le conteneur
est multi-homé (réseau backbone + réseau du site).

## Découverte / intégration avec les autres briques

- S'enregistre dans etcd sous `/skydns/fr/securepulse/<site>/storage/<site>-vip`
  et `/skydns/fr/securepulse/all/storage/<site>-vip` → résolu en DNS par
  CoreDNS (`DNS/`) comme `storage.<site>.securepulse.fr` / `storage.all.securepulse.fr`.
- `Mail/` monte ce NFS (`storage.<site>.securepulse.fr:/mail`) au lieu d'un
  volume Docker local.
- `LB-Syo/` peut résoudre `storage.all.securepulse.fr` pour un usage futur de
  supervision, mais ne pilote pas Pacemaker (cf. décision d'architecture
  validée avec l'équipe : Pacemaker doit être colocalisé avec les nœuds qu'il
  supervise).

## Tests

```sh
cd tests
docker compose -f docker-compose.test.yml up -d --build   # 2 sites x 2 nœuds + etcd
./run_tests.sh                                             # suite de vérifications
docker compose -f docker-compose.test.yml down -v
```

Ports de test exposés à l'hôte (plage 15000-20000, debug uniquement) :

| Port hôte | Service |
|---|---|
| 15379 | etcd (API HTTP, debug) |
| 15001-15004 | NFSv4 des 4 nœuds de test (site-a-1/2, site-b-1/2) |

La suite `run_tests.sh` vérifie, dans l'ordre : formation du cluster
GlusterFS, démarrage du volume replica-2, montage FUSE sur les 2 nœuds,
**réplication synchrone intra-DC** (écriture sur un nœud, lecture immédiate
sur l'autre), NFS-Ganesha actif, quorum Pacemaker + VIP assignée,
**failover** (arrêt du porteur de VIP → bascule sur le survivant),
enregistrement etcd, et démarrage d'une session de **géo-réplication
asynchrone inter-DC**.

## Écart avec le rapport

Aucun — cette brique n'est pas décrite explicitement dans le rapport en tant
que composant séparé nommé, mais elle implémente fidèlement le comportement
qu'il décrit (§39-41, §56 : GlusterFS + RAID + NFS par DC) tout en comblant
un point non traité par le rapport (panne du serveur de stockage lui-même,
pas seulement panne disque). Voir `Projet Annuel.docx` et le plan
d'implémentation pour le détail de cette décision.
