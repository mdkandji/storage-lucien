#!/bin/bash
set -e

ETCD_URL="${ETCD_URL:-http://etcd:2379}"
SITE="${SITE:-local}"
STORAGE_ID="${STORAGE_ID:-1}"
STORAGE_VIP="${STORAGE_VIP:?STORAGE_VIP env var is required: floating IP for this DC storage pair}"
STORAGE_VIP_CIDR="${STORAGE_VIP_CIDR:-24}"
GLUSTER_VOL="gvol-${SITE}"
GEOREP_KEY="/var/lib/glusterd/geo-replication/secret.pem"

# ── etcd helpers (same pattern as LDAP/Mail/DNS repos) ──────────────────────

_b64()  { printf '%s' "$1" | base64 -w0; }
_b64d() { printf '%s' "$1" | base64 -d 2>/dev/null; }

wait_etcd() {
    echo "[etcd] Waiting..."
    until curl -sf "${ETCD_URL}/health" > /dev/null 2>&1; do sleep 1; done
    echo "[etcd] Ready"
}

etcd_put() {
    curl -sf -X POST "${ETCD_URL}/v3/kv/put" \
        -H 'Content-Type: application/json' \
        -d "{\"key\":\"$(_b64 "$1")\",\"value\":\"$(_b64 "$2")\"}" > /dev/null
}

etcd_del() {
    curl -sf -X POST "${ETCD_URL}/v3/kv/deleterange" \
        -H 'Content-Type: application/json' \
        -d "{\"key\":\"$(_b64 "$1")\"}" > /dev/null
}

etcd_list() {
    local prefix="$1" end
    end=$(printf '%s' "$prefix" | sed 's|/$|0|')
    curl -sf -X POST "${ETCD_URL}/v3/kv/range" \
        -H 'Content-Type: application/json' \
        -d "{\"key\":\"$(_b64 "$prefix")\",\"range_end\":\"$(_b64 "$end")\"}" | \
        jq -r '.kvs[]?.value // empty' | \
        while read -r b64; do _b64d "$b64"; printf '\n'; done
}

# A storage node is multi-homed (backbone network + its site network), so we
# can't assume the site NIC is named "eth0" — Docker's interface naming order
# across multiple attached networks isn't guaranteed. Instead, find whichever
# NIC actually carries an IP in the same /24 as the DC's floating VIP (the VIP
# has to be added on that NIC by Pacemaker/IPaddr2, and corosync's ring0_addr
# has to be reachable by the peer over that same network).
detect_nic_and_ip() {
    local prefix="$1"
    local nic ip
    for nic in $(ls /sys/class/net | grep -v '^lo$'); do
        ip=$(ip -4 addr show "$nic" 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' | head -1)
        case "$ip" in
            ${prefix}*) echo "${nic} ${ip}"; return 0 ;;
        esac
    done
    return 1
}

NIC_AND_IP=$(detect_nic_and_ip "${STORAGE_VIP%.*}.") || { echo "[start] FATAL: no NIC found in VIP subnet ${STORAGE_VIP%.*}.0/24"; exit 1; }
MY_NIC=$(echo "$NIC_AND_IP" | awk '{print $1}')
MY_IP=$(echo "$NIC_AND_IP" | awk '{print $2}')

# Inter-DC transport address for geo-replication is just MY_IP: GlusterFS's
# client/brick protocol connects directly to each brick's configured IP (not
# just a single "entrypoint"), so geo-replication needs real, routed subnet
# reachability between the two DCs' storage LANs — provided in production by
# the site-to-site WireGuard mesh (LB-Syo). Not something storage-lucien's
# own code needs to special-case; see tests/docker-compose.test.yml for how
# the isolated test simulates that routing without depending on LB-Syo.
MY_WAN_IP="$MY_IP"
echo "[start] site=${SITE} id=${STORAGE_ID} nic=${MY_NIC} ip=${MY_IP} vip=${STORAGE_VIP}"

# ── node registration + local (same-DC) peer discovery ──────────────────────

register_node() {
    etcd_put "/storage-nodes/${SITE}/${HOSTNAME}" \
        "{\"host\":\"${MY_IP}\",\"id\":${STORAGE_ID},\"name\":\"${HOSTNAME}\"}"
}

deregister_node() {
    etcd_del "/storage-nodes/${SITE}/${HOSTNAME}"
}

# Waits for the other storage node of the SAME site to register itself,
# returns its ip/id/name on stdout as "ip id name". A DC always has exactly
# 2 storage nodes (per design), so we wait for exactly one peer.
discover_local_peer() {
    local tries=0
    while [ $tries -lt 90 ]; do
        etcd_list "/storage-nodes/${SITE}/" | while read -r n; do
            [ -z "$n" ] && continue
            printf '%s\n' "$n"
        done > /tmp/peers.json
        while read -r n; do
            [ -z "$n" ] && continue
            name=$(printf '%s' "$n" | jq -r '.name')
            [ "$name" = "$HOSTNAME" ] && continue
            ip=$(printf '%s' "$n" | jq -r '.host')
            id=$(printf '%s' "$n" | jq -r '.id')
            echo "${ip} ${id} ${name}"
            return 0
        done < /tmp/peers.json
        tries=$((tries + 1))
        sleep 2
    done
    return 1
}

# ── corosync / pacemaker ─────────────────────────────────────────────────────

setup_corosync() {
    local peer_ip="$1" peer_id="$2" peer_name="$3"
    SELF_IP="$MY_IP" SELF_ID="$STORAGE_ID" SELF_NAME="$HOSTNAME" \
    PEER_IP="$peer_ip" PEER_ID="$peer_id" PEER_NAME="$peer_name" \
    SITE="$SITE" \
        envsubst < /etc/corosync/corosync.conf.tpl > /etc/corosync/corosync.conf
    echo "[corosync] config written for site=${SITE} (self=${STORAGE_ID}/${MY_IP} peer=${peer_id}/${peer_ip})"
}

start_cluster_stack() {
    echo "[corosync] starting..."
    /usr/sbin/corosync -f &
    COROSYNC_PID=$!
    for i in $(seq 1 30); do
        corosync-cfgtool -s > /dev/null 2>&1 && break
        sleep 1
    done

    echo "[pacemaker] starting pacemakerd..."
    /usr/sbin/pacemakerd -f &
    PACEMAKERD_PID=$!
    for i in $(seq 1 30); do
        crm_mon -1 > /dev/null 2>&1 && break
        sleep 2
    done
}

# ── glusterd / volume / mount ────────────────────────────────────────────────

start_glusterd() {
    mkdir -p /var/log/glusterfs /data/brick/gvol
    glusterd -N --log-level INFO &
    GLUSTERD_PID=$!
    for i in $(seq 1 30); do
        gluster peer status > /dev/null 2>&1 && break
        sleep 1
    done
}

setup_volume() {
    local peer_ip="$1" peer_id="$2"
    if [ "$STORAGE_ID" -lt "$peer_id" ]; then
        echo "[gluster] (id=${STORAGE_ID}, lowest) probing peer ${peer_ip}..."
        for i in $(seq 1 30); do
            gluster peer probe "$peer_ip" && break
            sleep 2
        done
        for i in $(seq 1 30); do
            gluster peer status | grep -qi "State: Peer in Cluster" && break
            sleep 2
        done
        if ! gluster volume info "$GLUSTER_VOL" > /dev/null 2>&1; then
            echo "[gluster] creating replica-2 volume ${GLUSTER_VOL}..."
            gluster volume create "$GLUSTER_VOL" replica 2 \
                "${MY_IP}:/data/brick/gvol" "${peer_ip}:/data/brick/gvol" force
            gluster volume set "$GLUSTER_VOL" nfs.disable on
            gluster volume start "$GLUSTER_VOL"
        fi
    else
        echo "[gluster] (id=${STORAGE_ID}) waiting for peer to create ${GLUSTER_VOL}..."
        for i in $(seq 1 60); do
            gluster volume info "$GLUSTER_VOL" > /dev/null 2>&1 && break
            sleep 2
        done
    fi

    for i in $(seq 1 30); do
        gluster volume status "$GLUSTER_VOL" > /dev/null 2>&1 && break
        sleep 2
    done
}

mount_volume() {
    echo "[mount] mounting ${GLUSTER_VOL} on /export/mail..."
    for i in $(seq 1 30); do
        mount -t glusterfs "localhost:/${GLUSTER_VOL}" /export/mail 2>/tmp/mount.err && break
        sleep 2
    done
    mountpoint -q /export/mail || { echo "[mount] FAILED"; cat /tmp/mount.err; exit 1; }
    echo "[mount] OK"
}

start_ganesha() {
    mkdir -p /var/run/ganesha
    GLUSTER_VOL="$GLUSTER_VOL" envsubst '${GLUSTER_VOL}' \
        < /etc/ganesha/ganesha.conf.tpl > /etc/ganesha/ganesha.conf
    echo "[ganesha] starting NFS-Ganesha (FSAL_GLUSTER, volume=${GLUSTER_VOL})..."
    /usr/bin/ganesha.nfsd -F -L /var/log/ganesha.log &
    GANESHA_PID=$!
}

# ── georep ssh trust (per-node keypair, pubkeys exchanged via etcd) ─────────

setup_georep_ssh() {
    mkdir -p "$(dirname "$GEOREP_KEY")" /root/.ssh
    chmod 700 /root/.ssh
    if [ ! -f "$GEOREP_KEY" ]; then
        ssh-keygen -t ed25519 -N '' -f "$GEOREP_KEY" -C "georep-${SITE}-${HOSTNAME}" > /dev/null
    fi
    # gluster's own "is passwordless ssh set up?" precheck (run before the
    # push-pem exchange) shells out to plain `ssh host` with no -i flag, so
    # it only finds a key via ssh's default identity file lookup — symlink
    # our named georep key there too, otherwise `gluster volume
    # geo-replication ... create push-pem` fails before it even starts.
    ln -sf "$GEOREP_KEY" /root/.ssh/id_ed25519
    ln -sf "${GEOREP_KEY}.pub" /root/.ssh/id_ed25519.pub
    etcd_put "/georep-keys/${SITE}/${HOSTNAME}" "$(cat "${GEOREP_KEY}.pub")"
    # Closed simulation network between trusted DCs (no public internet exposure) ->
    # host key TOFU is an acceptable simplification here, NOT how you'd run this
    # across real, independently-administered sites (there you'd provision
    # known_hosts out of band). Documented limitation, see README.
    cat > /root/.ssh/config << EOF
Host *
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
EOF
    chmod 600 /root/.ssh/config
    /usr/sbin/sshd
}

sync_georep_trust() {
    touch /root/.ssh/authorized_keys
    etcd_list "/georep-keys/" | while read -r pub; do
        [ -z "$pub" ] && continue
        grep -qF "$pub" /root/.ssh/authorized_keys 2>/dev/null || echo "$pub" >> /root/.ssh/authorized_keys
    done
    chmod 600 /root/.ssh/authorized_keys
}

# ── inter-DC async geo-replication (discovered dynamically via etcd) ────────

# Path of the gsyncd binary invoked over SSH on the *secondary* node. The
# Debian package doesn't install it at GlusterFS's upstream-default hardcoded
# path, so every geo-replication session needs an explicit `config
# remote-gsyncd` pointing at wherever this distro actually put it, or every
# worker dies with "No such file or directory: /nonexistent/gsyncd".
find_gsyncd_path() {
    find /usr/lib* -name gsyncd -type f 2>/dev/null | head -1
}

setup_georep_sessions() {
    [ "$STORAGE_ID" != "1" ] && return 0   # one side per DC drives session setup

    # Required once before the first push-pem session: aggregates every
    # local node's geo-rep pubkey into common_secret.pem.pub.
    gluster system:: execute gsec_create > /dev/null 2>&1 || true

    local gsyncd_path
    gsyncd_path=$(find_gsyncd_path)

    etcd_list "/skydns/fr/securepulse/all/storage-transport/" | while read -r entry; do
        [ -z "$entry" ] && continue
        peer_ip=$(printf '%s' "$entry" | jq -r '.host // empty')
        peer_site=$(printf '%s' "$entry" | jq -r '.site // empty')
        [ -z "$peer_ip" ] || [ "$peer_ip" = "$MY_WAN_IP" ] && continue
        [ -z "$peer_site" ] || [ "$peer_site" = "$SITE" ] && continue
        # `gluster ... status` prints a non-empty "No active geo-replication
        # sessions..." message even when there is NO session — an empty
        # string check is not enough — and the "No active..." explanation
        # text itself contains the peer's IP (e.g. "No active
        # geo-replication sessions between gvol-site-a and 10.x.x.x::vol"),
        # so grepping for the peer IP alone false-positives too. Only a real
        # status keyword on a real status line confirms a session exists.
        session_status=$(gluster volume geo-replication "$GLUSTER_VOL" "${peer_ip}::gvol-${peer_site}" status 2>/dev/null || true)
        if ! printf '%s' "$session_status" | grep -E -q "Active|Passive|Faulty|Initializing"; then
            echo "[georep] creating async session ${GLUSTER_VOL} -> ${peer_site} (${peer_ip})"
            gluster volume geo-replication "$GLUSTER_VOL" "root@${peer_ip}::gvol-${peer_site}" create push-pem force 2>/tmp/georep.err || {
                echo "[georep] session to ${peer_site} not ready yet: $(tail -1 /tmp/georep.err 2>/dev/null)"
                continue
            }
            if [ -n "$gsyncd_path" ]; then
                gluster volume geo-replication "$GLUSTER_VOL" "root@${peer_ip}::gvol-${peer_site}" \
                    config remote-gsyncd "$gsyncd_path" > /dev/null 2>&1 || true
            fi
            gluster volume geo-replication "$GLUSTER_VOL" "root@${peer_ip}::gvol-${peer_site}" start 2>>/tmp/georep.err \
                || echo "[georep] failed to start session to ${peer_site}: $(tail -1 /tmp/georep.err 2>/dev/null)"
        fi
    done
}

# GlusterFS's geo-replication `create` automatically marks whichever volume
# it targets as SECONDARY read-only (a sane default for its usual one-way
# DR use case). Our design is multi-master by nature: mail arrives locally
# at whichever DC the client used and asynchronously replicates outward, so
# EVERY site creates a session targeting every OTHER site (bidirectional
# between each pair) — which means every volume eventually gets marked
# secondary-of-something and goes read-only, breaking local mail writes.
# We deliberately override that safety lock: local writes must always stay
# possible, replication conflicts on the rare case of the same mailbox
# written concurrently on two DCs are an accepted limitation (the report
# itself doesn't solve this either — see storage-lucien/README.md).
ensure_local_writable() {
    gluster volume set "$GLUSTER_VOL" features.read-only off > /dev/null 2>&1 || true
}

watch_georep_peers() {
    while true; do
        sync_georep_trust 2>/dev/null || true
        setup_georep_sessions 2>/dev/null || true
        ensure_local_writable
        sleep 30
    done
}

# ── VIP + service discovery registration ─────────────────────────────────────

register_storage_service() {
    [ "$STORAGE_ID" != "1" ] && return 0   # single VIP per site, register once
    etcd_put "/skydns/fr/securepulse/${SITE}/storage/${SITE}-vip" "{\"host\":\"${STORAGE_VIP}\"}"
    etcd_put "/skydns/fr/securepulse/all/storage/${SITE}-vip" "{\"host\":\"${STORAGE_VIP}\",\"site\":\"${SITE}\"}"
    # Separate from the intra-DC VIP on purpose (see MY_WAN_IP comment above):
    # geo-replication transport isn't Pacemaker-managed, it targets whichever
    # node currently drives the session (id=1), reachable over the site's
    # WireGuard-routed subnet in production.
    etcd_put "/skydns/fr/securepulse/all/storage-transport/${SITE}" "{\"host\":\"${MY_WAN_IP}\",\"site\":\"${SITE}\"}"
    echo "[register] storage VIP ${STORAGE_VIP} (transport ${MY_WAN_IP}) registered for site=${SITE}"
}

deregister_storage_service() {
    [ "$STORAGE_ID" != "1" ] && return 0
    etcd_del "/skydns/fr/securepulse/${SITE}/storage/${SITE}-vip"
    etcd_del "/skydns/fr/securepulse/all/storage/${SITE}-vip"
    etcd_del "/skydns/fr/securepulse/all/storage-transport/${SITE}"
}

# ── shutdown ──────────────────────────────────────────────────────────────────

cleanup() {
    echo "[shutdown] SIGTERM received"
    deregister_node
    deregister_storage_service
    [ -n "$GANESHA_PID" ] && kill "$GANESHA_PID" 2>/dev/null || true
    [ -n "$PACEMAKERD_PID" ] && kill "$PACEMAKERD_PID" 2>/dev/null || true
    [ -n "$COROSYNC_PID" ] && kill "$COROSYNC_PID" 2>/dev/null || true
    umount /export/mail 2>/dev/null || true
    exit 0
}

###############################################################################
# MAIN
###############################################################################

wait_etcd
register_node

echo "[discover] waiting for local peer (same site, other id)..."
PEER_INFO=$(discover_local_peer) || { echo "[discover] FAILED: no peer found"; exit 1; }
PEER_IP=$(echo "$PEER_INFO" | awk '{print $1}')
PEER_ID=$(echo "$PEER_INFO" | awk '{print $2}')
PEER_NAME=$(echo "$PEER_INFO" | awk '{print $3}')
echo "[discover] peer found: ${PEER_NAME} id=${PEER_ID} ip=${PEER_IP}"

trap cleanup TERM INT

start_glusterd
setup_volume "$PEER_IP" "$PEER_ID"
mount_volume
start_ganesha

setup_corosync "$PEER_IP" "$PEER_ID" "$PEER_NAME"
start_cluster_stack

if [ "$STORAGE_ID" -lt "$PEER_ID" ]; then
    /opt/storage-lucien/configure-cluster.sh "$STORAGE_VIP" "$STORAGE_VIP_CIDR" "$MY_NIC"
fi

register_storage_service
setup_georep_ssh
sync_georep_trust
watch_georep_peers &

echo "[ready] storage-lucien node ${HOSTNAME} (site=${SITE}, id=${STORAGE_ID}) operational"

wait "$GLUSTERD_PID"
