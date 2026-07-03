# Changelog — storage-lucien

## [Unreleased]

### Ajouté
- Création du repo : brique stockage manquante identifiée lors de
  l'alignement du code sur `Projet Annuel.docx` (GlusterFS et HA du stockage
  absents partout ailleurs dans le code existant).
- GlusterFS replica-2 intra-DC (2 nœuds, réplication synchrone) avec
  découverte du pair local via etcd (`/storage-nodes/<site>/`).
- Export NFSv4 via NFS-Ganesha (FSAL_GLUSTER/libgfapi, accès natif au volume
  — voir "Corrigé" plus bas pour l'historique VFS→GLUSTER), actif en
  permanence sur les 2 nœuds.
- Cluster Pacemaker/Corosync (2 nœuds, transport `udpu`) pilotant une VIP
  flottante unique (`ocf:heartbeat:IPaddr2`) — bascule automatique en cas de
  panne du nœud actif.
- Géo-réplication GlusterFS asynchrone inter-DC, sessions établies
  dynamiquement via découverte etcd des VIPs des autres sites, confiance SSH
  échangée via etcd (pas de clé statique committée).
- Enregistrement etcd (`/skydns/.../storage/...`) pour découverte par
  `Mail/` et `LB-Syo/`.
- Suite de tests d'intégration (`tests/`) : formation cluster GlusterFS,
  montage, réplication sync intra-DC, NFS-Ganesha, quorum + VIP Pacemaker,
  failover, registration etcd, géo-réplication async, propagation réelle de
  données inter-DC.

### Corrigé (bugs trouvés en testant, tous confirmés en environnement Docker réel)
- `cibadmin --create` exigeait un attribut `interval` explicite sur
  **tous** les `<op>` (y compris `start`/`stop`), pas seulement `monitor` —
  sinon rejet schema silencieux du CIB.
- `crmsh` (bug connu de la version packagée Debian bookworm, commit par
  diff cassé) remplacé par `cibadmin`/`crm_attribute` directs.
- `ganesha.nfsd` échouait faute de `/var/run/ganesha` (non créé).
- Géo-réplication : la commande `status` retourne un texte non-vide même
  sans session active ("No active geo-replication sessions...", qui
  contient même l'IP du pair dans son message d'erreur) — la détection de
  session existante se fait désormais sur des mots-clés de statut réels
  (Active/Passive/Faulty/Initializing), pas sur une simple absence de
  sortie ni une recherche naïve de l'IP.
- Géo-réplication : préalable `gluster system:: execute gsec_create`
  manquant, et chemin `gsyncd` mal détecté par le paquet Debian
  (`/nonexistent/gsyncd`) — `config remote-gsyncd` explicite ajouté.
  Paquet `rsync` manquant (transfert des données) ajouté au Dockerfile.
- Géo-réplication bidirectionnelle (nécessaire pour notre modèle
  multi-maître) déclenche le verrou de sécurité GlusterFS qui marque
  chaque volume "secondaire" en lecture seule — cassant les écritures
  locales sur les deux DC. Contourné explicitement (`ensure_local_writable`,
  voir README section dédiée).
- `FSAL { Name = VFS }` échouait la validation de config NFS-Ganesha
  (`unknown property`) : le paquet `nfs-ganesha` de Debian bookworm ne
  fournit **pas** de bibliothèque FSAL VFS (seule `nfs-ganesha-gluster`
  existe séparément). Basculé sur `FSAL_GLUSTER` (accès natif via libgfapi
  au volume, sans repasser par le montage FUSE local) — trouvé et corrigé
  en construisant les tests d'intégration de `Mail/`.
- **Course entre le montage FUSE local et la disponibilité du brick
  GlusterFS**, repérée en construisant `integration/` (4 sites démarrant
  GlusterFS/Pacemaker/Corosync simultanément, jamais reproduit sur les
  tests à 2 nœuds de ce repo, moins chargés) : `mount -t glusterfs` réussit
  dès que le montage FUSE est enregistré côté noyau, mais le client
  glusterfs négocie ensuite la connexion aux bricks de façon asynchrone et
  se démonte tout seul si aucune n'est encore joignable ("no subvolumes
  up" dans les logs glusterfs). `mount && break` ne détectait donc pas cet
  échec différé. `mount_volume()` vérifie désormais que le point de
  montage sert vraiment des données (`stat` réussi) avant de continuer.
  **Correctif révisé** : la première version de ce correctif redémontait
  (`umount -l`) entre chaque tentative — ce qui s'est avéré interrompre la
  négociation GlusterFS en cours avant qu'elle n'aboutisse, faisant
  régresser les tests à 2 nœuds de ce repo (passaient à 13/13 avant, à
  6/12 avec cette première version). `mount_volume()` monte désormais une
  seule fois puis patiente (sans redémonter) que le montage devienne
  utilisable — confirmé stable sur 2 runs propres consécutifs (13/13
  à chaque fois) après ce second correctif.
  **Troisième correctif** : ce montage unique en tête de fonction n'était
  pas protégé contre `set -e` (actif en tête de ce script) — si le
  `glusterd` local n'a même pas encore son socket prêt au tout premier
  essai (constaté en réintégrant ce correctif dans `integration/`, sous la
  charge de 4 sites démarrant simultanément), `mount` retourne aussitôt un
  code non-zéro et `set -e` tue le conteneur sur-le-champ, avant même
  d'atteindre la boucle d'attente — crash-loop silencieux, sans même le
  message `[mount] FAILED`. `mount_volume()` retente maintenant le `mount`
  lui-même (protégé par `|| true`) à chaque itération tant qu'il n'est pas
  déjà monté, en plus d'attendre qu'il devienne utilisable une fois monté.
  Confirmé stable : les 8 nœuds storage de `integration/` démarrent
  désormais avec 0 redémarrage, et la suite `integration/tests/` passe
  intégralement (18 OK / 0 FAIL / 1 SKIP attendu).

### Découvert (limitation d'environnement, pas un bug de ce repo)
- Montage NFSv4 **cross-conteneur** bloqué sur l'hôte de développement
  utilisé pour ce projet (`access denied by server`), alors que le montage
  local (même conteneur) réussit systématiquement — reproduit à l'identique
  avec NFS-Ganesha et avec le serveur NFS du noyau Linux, sur plusieurs
  sous-réseaux Docker, connectivité réseau intégralement vérifiée. Very
  probablement une interaction conntrack/netfilter spécifique à cet hôte.
  Documentation complète de l'investigation dans le README (section
  Limitations connues) et dans `Mail/CHANGELOG.md`.
