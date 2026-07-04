#!/bin/bash
set -e

echo "=== [SecurePulse] Attente du démarrage de GlusterFS ==="
sleep 5

echo "=== Connexion des nœuds du cluster (Peer Probe) ==="
docker exec gluster-paris gluster peer probe 192.168.220.12
docker exec gluster-paris gluster peer probe 192.168.220.13

echo "=== Vérification du statut du cluster ==="
docker exec gluster-paris gluster peer status

echo "=== Création du volume répliqué multi-site (Anti-SPOF) ==="
docker exec gluster-paris mkdir -p /data/glusterfs/brick1/gv0
docker exec gluster-lille mkdir -p /data/glusterfs/brick1/gv0
docker exec gluster-lyon mkdir -p /data/glusterfs/brick1/gv0

docker exec gluster-paris gluster volume create securepulse-vol replica 3 \
  192.168.220.11:/data/glusterfs/brick1/gv0 \
  192.168.220.12:/data/glusterfs/brick1/gv0 \
  192.168.220.13:/data/glusterfs/brick1/gv0 \
  force

echo "=== Démarrage du volume ==="
docker exec gluster-paris gluster volume start securepulse-vol

echo "=== Statut final du volume GlusterFS ==="
docker exec gluster-paris gluster volume info