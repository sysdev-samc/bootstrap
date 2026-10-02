#!/usr/bin/env bash
# =============================================================================
# install-k3s-lab.sh — k3s HA (etcd à 3 membres) + réplication des données (Longhorn)
# =============================================================================
#
# OBJECTIF
#   1. Pouvoir continuer à piloter le cluster (kubectl, déploiements...) même si
#      le premier serveur tombe : control plane et base etcd sur 3 machines.
#   2. Avoir des volumes persistants RÉPLIQUÉS sur les 2 machines de travail.
#
# ARCHITECTURE
#   machine A = serveur k3s n°1 : etcd + control plane + worker   -> server
#   machine B = serveur k3s n°2 : etcd + control plane + worker   -> server-join
#   machine C = serveur k3s n°3 : etcd + control plane SEULEMENT  -> server-join
#               (petit nœud : NAS, mini-PC, Raspberry Pi... il ne fait tourner
#               aucun pod applicatif, il sert à départager le quorum etcd)
#   Longhorn  = stockage répliqué sur A et B                      -> longhorn
#
# POURQUOI 3 MEMBRES ETCD ET PAS 2 ?
#   etcd n'accepte une écriture que si la MAJORITÉ des membres répond (quorum).
#     2 membres : majorité = 2 -> si un tombe, plus de quorum, l'API ne répond
#                 plus : c'est PIRE qu'un serveur unique (2 pannes possibles).
#     3 membres : majorité = 2 -> un membre peut tomber, le cluster reste pilotable.
#   Toujours un nombre IMPAIR de membres (3, 5...).
#
# UTILISATION (root ou sudo, Debian/Ubuntu) — les serveurs se joignent UN PAR UN
#   A : sudo K3S_TLS_SAN=k3s.lab.local ./install-k3s-lab.sh server
#       (affiche le token et les commandes pour B et C)
#   B : sudo K3S_URL=https://IP_A:6443 K3S_TOKEN=xxxx ./install-k3s-lab.sh server-join
#   C : sudo K3S_URL=https://IP_A:6443 K3S_TOKEN=xxxx CONTROL_PLANE_ONLY=1 \
#            ./install-k3s-lab.sh server-join
#       (Raspberry Pi 3 : remplace CONTROL_PLANE_ONLY=1 par ETCD_ONLY=1, et
#        utilise Debian 64 bits (arm64) avec les données sur un SSD USB, pas la carte SD)
#   A : sudo ./install-k3s-lab.sh longhorn
#       ./install-k3s-lab.sh test        (vérifie la réplication des volumes)
#       ./install-k3s-lab.sh status      (vérifie etcd, nœuds et snapshots)
#   Worker supplémentaire éventuel : ... ./install-k3s-lab.sh agent
#
# PORTS À OUVRIR ENTRE LES MACHINES (si pare-feu actif)
#   6443/tcp        API Kubernetes
#   2379-2380/tcp   etcd (clients et réplication entre serveurs) : entre serveurs
#   8472/udp        réseau des pods (Flannel VXLAN) : indispensable, sinon Longhorn
#                   ne peut pas répliquer entre les nœuds
#   10250/tcp       kubelet (logs, exec, métriques)
#
# ATTENTION AU DISQUE DES SERVEURS ETCD
#   etcd écrit en continu et attend que le disque confirme vite (fsync). Un
#   disque lent (HDD, RAID logiciel chargé) provoque des timeouts et des
#   changements de leader. Les données etcd sont dans /var/lib/rancher/k3s/server/db :
#   garde-les sur un SSD (disque système), pas sur un gros volume de stockage.
#
# VARIABLES OPTIONNELLES
#   K3S_TLS_SAN         nom ou IP stable pour joindre l'API (DNS, IP virtuelle...)
#                       -> permet de piloter le cluster sans dépendre de l'IP de A
#   CONTROL_PLANE_ONLY  1 = ce serveur ne reçoit aucun pod applicatif (machine C)
#   ETCD_ONLY           1 = machine C ne fait tourner QUE etcd (ni API, ni scheduler,
#                       ni controller-manager) : recommandé pour un Raspberry Pi 3
#                       (1 Go de RAM). Implique CONTROL_PLANE_ONLY. Pas de kubectl
#                       sur cette machine : le contrôle se fait depuis A ou B.
#   ETCD_RELAXED_TIMEOUTS  1 = timeouts etcd plus tolérants (heartbeat 300 ms,
#                       élection 3 s) si le disque ou le réseau d'un membre est lent.
#                       À mettre IDENTIQUE sur les 3 serveurs.
#   K3S_VERSION         ex: v1.33.4+k3s1 (vide = dernière version stable)
#                       Garde la MÊME version sur tous les serveurs.
#   LONGHORN_VERSION    ex: 1.9.1 (vide = dernière version du chart ; épingle-la
#                       après la première installation)
#   LONGHORN_DATA_PATH  dossier des données Longhorn (défaut /var/lib/longhorn)
#   REPLICAS            nombre de copies de chaque volume (défaut 2)
# =============================================================================

set -euo pipefail

K3S_VERSION="${K3S_VERSION:-}"
K3S_URL="${K3S_URL:-}"
K3S_TOKEN="${K3S_TOKEN:-}"
K3S_TLS_SAN="${K3S_TLS_SAN:-}"
CONTROL_PLANE_ONLY="${CONTROL_PLANE_ONLY:-0}"
ETCD_ONLY="${ETCD_ONLY:-0}"
ETCD_RELAXED_TIMEOUTS="${ETCD_RELAXED_TIMEOUTS:-0}"
LONGHORN_VERSION="${LONGHORN_VERSION:-}"
LONGHORN_DATA_PATH="${LONGHORN_DATA_PATH:-/var/lib/longhorn}"
REPLICAS="${REPLICAS:-2}"
KUBECONFIG_PATH="/etc/rancher/k3s/k3s.yaml"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mATTENTION: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Lance ce script en root (sudo)."
}

# -----------------------------------------------------------------------------
# ÉTAPE 1 — Prérequis (sur TOUTES les machines qui feront tourner Longhorn)
# -----------------------------------------------------------------------------
# Longhorn expose chaque volume au pod via iSCSI : il faut donc open-iscsi
# (le démon iscsid) sur chaque nœud. nfs-common permet les volumes partagés
# (RWX) et les sauvegardes vers un NFS. cryptsetup/dmsetup servent au
# chiffrement et à la gestion des périphériques de bloc.
# (Installés aussi sur la machine C : inoffensif, et pratique si elle change de rôle.)
prereqs() {
  need_root
  log "Installation des paquets requis (open-iscsi, nfs-common, ...)"
  apt-get update -y
  apt-get install -y open-iscsi nfs-common cryptsetup dmsetup curl ca-certificates

  log "Activation du démon iSCSI"
  systemctl enable --now iscsid
  modprobe iscsi_tcp || warn "Module iscsi_tcp non chargé"
  echo iscsi_tcp > /etc/modules-load.d/iscsi_tcp.conf

  # Si multipathd est présent, il « vole » les disques virtuels créés par
  # Longhorn (/dev/sdX) et fait échouer le montage des volumes. On l'en écarte.
  if command -v multipathd >/dev/null 2>&1; then
    if ! grep -q 'devnode "^sd\[a-z0-9\]+"' /etc/multipath.conf 2>/dev/null; then
      log "multipathd détecté : exclusion des disques /dev/sdX"
      cat >> /etc/multipath.conf <<'EOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
      systemctl restart multipathd || true
    fi
  fi

  # Longhorn stocke les réplicas comme des fichiers dans un dossier : ext4 est
  # parfaitement supporté (xfs aussi). On vérifie ce dossier.
  mkdir -p "$LONGHORN_DATA_PATH"
  local fs
  fs="$(findmnt -no FSTYPE -T "$LONGHORN_DATA_PATH" || true)"
  log "Dossier de données Longhorn : $LONGHORN_DATA_PATH (système de fichiers : ${fs:-inconnu})"
  case "$fs" in
    ext4|xfs) ;;
    *) warn "Système de fichiers '$fs' : Longhorn recommande ext4 ou xfs." ;;
  esac
  df -h "$LONGHORN_DATA_PATH" | tail -1
}

# -----------------------------------------------------------------------------
# Fichier de configuration k3s (/etc/rancher/k3s/config.yaml)
# -----------------------------------------------------------------------------
# On passe par un fichier plutôt que par des options en ligne de commande :
# plus lisible, et les valeurs contenant des espaces (cron) y sont sans risque.
#
#   cluster-init          : (1er serveur) démarre un cluster avec etcd embarqué.
#                           Sans cette option, k3s utilise SQLite et ne peut
#                           PAS accepter d'autres serveurs.
#   server / token        : (serveurs suivants) où et comment rejoindre le cluster.
#   disable local-storage : supprime le stockage local non répliqué de k3s ;
#                           Longhorn devient la seule classe de stockage par défaut.
#                           Doit être identique sur tous les serveurs.
#   tls-san               : ajoute un nom/IP au certificat de l'API, pour pouvoir
#                           la joindre autrement que par l'IP de la machine A.
#   node-taint            : (machine C) interdit les pods applicatifs sur ce nœud.
#   disable-apiserver/controller-manager/scheduler : (ETCD_ONLY=1) le nœud ne fait
#                           tourner que etcd. Il vote au quorum mais ne sert pas
#                           l'API : très léger, idéal pour un Raspberry Pi 3.
#   etcd-arg              : (ETCD_RELAXED_TIMEOUTS=1) délais de heartbeat/élection
#                           plus larges, pour tolérer un membre lent.
#   etcd-snapshot-*       : sauvegarde automatique de la base etcd toutes les 6 h,
#                           20 conservées (dans /var/lib/rancher/k3s/server/db/snapshots).
write_k3s_config() {
  local mode="$1"   # init | join
  mkdir -p /etc/rancher/k3s
  (
    umask 077   # le fichier contient le token : lisible par root uniquement
    {
      if [ "$mode" = "init" ]; then
        echo "cluster-init: true"
      else
        echo "server: $K3S_URL"
        echo "token: $K3S_TOKEN"
      fi
      echo "disable:"
      echo "  - local-storage"
      if [ -n "$K3S_TLS_SAN" ]; then
        echo "tls-san:"
        echo "  - $K3S_TLS_SAN"
      fi
      if [ "$mode" = "join" ] && { [ "$CONTROL_PLANE_ONLY" = "1" ] || [ "$ETCD_ONLY" = "1" ]; }; then
        echo "node-taint:"
        echo "  - CriticalAddonsOnly=true:NoExecute"
      fi
      if [ "$mode" = "join" ] && [ "$ETCD_ONLY" = "1" ]; then
        echo "disable-apiserver: true"
        echo "disable-controller-manager: true"
        echo "disable-scheduler: true"
      fi
      if [ "$ETCD_RELAXED_TIMEOUTS" = "1" ]; then
        echo "etcd-arg:"
        echo "  - heartbeat-interval=300"
        echo "  - election-timeout=3000"
      fi
      echo 'etcd-snapshot-schedule-cron: "0 */6 * * *"'
      echo "etcd-snapshot-retention: 20"
    } > /etc/rancher/k3s/config.yaml
  )
}

# Installe le binaire k3s en mode serveur (la config est lue dans config.yaml).
install_k3s_server() {
  local -a envs=("INSTALL_K3S_EXEC=server")
  if [ -n "$K3S_VERSION" ]; then
    envs+=("INSTALL_K3S_VERSION=$K3S_VERSION")
  fi
  curl -sfL https://get.k3s.io | env "${envs[@]}" sh -

  # Un nœud etcd seul n'a pas d'API locale : kubectl y est inutilisable.
  if [ "$ETCD_ONLY" = "1" ]; then
    log "Nœud etcd seul : pas d'API locale. Vérifie depuis A ou B : ./install-k3s-lab.sh status"
    return 0
  fi

  log "Attente que le nœud soit prêt"
  local i
  for i in $(seq 1 60); do
    if k3s kubectl get nodes >/dev/null 2>&1; then break; fi
    sleep 3
  done
  k3s kubectl wait --for=condition=Ready "node/$(hostname)" --timeout=180s
}

# Copie le kubeconfig pour l'utilisateur qui a lancé sudo : il peut alors utiliser
# kubectl/helm sans être root. Le fichier d'origine reste en 600. Ce kubeconfig
# pointe vers 127.0.0.1 : sur CHAQUE serveur, kubectl parle donc à l'API locale,
# ce qui permet de piloter le cluster depuis B ou C si A est tombé.
setup_kubeconfig() {
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
    local home
    home="$(getent passwd "$SUDO_USER" | cut -d: -f6)"
    mkdir -p "$home/.kube"
    cp "$KUBECONFIG_PATH" "$home/.kube/config"
    chown -R "$SUDO_USER":"$(id -gn "$SUDO_USER")" "$home/.kube"
    chmod 600 "$home/.kube/config"
    log "kubeconfig copié dans $home/.kube/config"
  fi
}

# -----------------------------------------------------------------------------
# ÉTAPE 2 — Premier serveur (machine A) : crée le cluster etcd
# -----------------------------------------------------------------------------
server() {
  need_root
  prereqs
  log "Installation du 1er serveur k3s (etcd embarqué)"
  write_k3s_config init
  install_k3s_server
  setup_kubeconfig

  local ip
  ip="$(hostname -I | awk '{print $1}')"
  log "Serveur n°1 prêt. Joins les autres serveurs UN PAR UN :"
  echo "  Machine B :"
  echo "    sudo K3S_URL=https://${ip}:6443 K3S_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token) ./install-k3s-lab.sh server-join"
  echo "  Machine C (control plane seul) :"
  echo "    sudo K3S_URL=https://${ip}:6443 K3S_TOKEN=<même token> CONTROL_PLANE_ONLY=1 ./install-k3s-lab.sh server-join"
  warn "Le token donne un accès complet au cluster : ne le partage pas."
  warn "Tant que B et C ne sont pas joints, etcd n'a qu'un membre : pas de tolérance de panne."
  if [ -z "$K3S_TLS_SAN" ]; then
    warn "K3S_TLS_SAN non défini : l'API ne sera joignable à distance que par l'IP de cette machine."
  fi
}

# -----------------------------------------------------------------------------
# ÉTAPE 3 — Serveurs supplémentaires (machines B et C)
# -----------------------------------------------------------------------------
# Chaque serveur ajouté devient un membre etcd et un control plane complet.
# Ils se joignent UN PAR UN : attends que le nœud précédent soit Ready avant de
# lancer le suivant (un membre etcd en cours d'ajout fragilise temporairement
# le quorum).
server_join() {
  need_root
  [ -n "$K3S_URL" ] || die "K3S_URL manquant (ex: https://192.168.1.10:6443)"
  [ -n "$K3S_TOKEN" ] || die "K3S_TOKEN manquant (cf. sortie de la commande 'server')"
  prereqs
  log "Ajout de ce serveur au cluster (membre etcd + control plane)"
  write_k3s_config join
  install_k3s_server
  if [ "$ETCD_ONLY" != "1" ]; then
    setup_kubeconfig
  fi
  log "Serveur ajouté. Vérifie l'état : ./install-k3s-lab.sh status"
}

# -----------------------------------------------------------------------------
# Optionnel — Worker simple (sans etcd ni control plane)
# -----------------------------------------------------------------------------
agent() {
  need_root
  [ -n "$K3S_URL" ] || die "K3S_URL manquant"
  [ -n "$K3S_TOKEN" ] || die "K3S_TOKEN manquant"
  prereqs
  log "Installation d'un agent k3s"
  local -a envs=("INSTALL_K3S_EXEC=agent" "K3S_URL=$K3S_URL" "K3S_TOKEN=$K3S_TOKEN")
  if [ -n "$K3S_VERSION" ]; then
    envs+=("INSTALL_K3S_VERSION=$K3S_VERSION")
  fi
  curl -sfL https://get.k3s.io | env "${envs[@]}" sh -
}

# -----------------------------------------------------------------------------
# ÉTAPE 4 — Longhorn (depuis un serveur, une seule fois)
# -----------------------------------------------------------------------------
# Longhorn crée pour chaque volume persistant (PVC) N copies (réplicas), chacune
# sur un nœud différent, et les garde synchronisées en écriture. Si un nœud
# tombe, le volume reste accessible via la copie de l'autre nœud, puis se
# resynchronise automatiquement au retour du nœud.
#
# Réglages posés ici :
#   defaultReplicaCount / defaultClassReplicaCount = REPLICAS
#       -> chaque volume a 2 copies (une sur A, une sur B). La machine C, qui
#          porte le taint, ne reçoit ni pod Longhorn ni données.
#   defaultDataPath = LONGHORN_DATA_PATH
#       -> où sont stockées les copies sur le disque ext4 de chaque machine.
longhorn() {
  need_root
  export KUBECONFIG="$KUBECONFIG_PATH"

  # Nœuds pouvant porter des données : ceux sans le taint CriticalAddonsOnly.
  local workers
  workers="$(k3s kubectl get nodes --no-headers \
    -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints[*].key \
    | grep -vc CriticalAddonsOnly || true)"
  if [ "$workers" -lt "$REPLICAS" ]; then
    warn "Seulement $workers nœud(s) de stockage pour $REPLICAS réplicas : volumes 'degraded'."
    warn "Joins d'abord la machine B (server-join)."
  fi

  if ! command -v helm >/dev/null 2>&1; then
    log "Installation de Helm (gestionnaire de paquets Kubernetes)"
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  fi

  log "Installation de Longhorn"
  helm repo add longhorn https://charts.longhorn.io
  helm repo update

  local -a vargs=()
  if [ -n "$LONGHORN_VERSION" ]; then
    vargs+=(--version "$LONGHORN_VERSION")
  fi

  helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system --create-namespace \
    "${vargs[@]}" \
    --set defaultSettings.defaultReplicaCount="$REPLICAS" \
    --set persistence.defaultClassReplicaCount="$REPLICAS" \
    --set defaultSettings.defaultDataPath="$LONGHORN_DATA_PATH" \
    --wait --timeout 15m

  log "Longhorn installé. Classes de stockage :"
  k3s kubectl get storageclass
  cat <<'EOF'

Interface web (locale, non exposée) :
  kubectl -n longhorn-system port-forward svc/longhorn-frontend 8080:80
  puis ouvre http://localhost:8080
EOF
}

# -----------------------------------------------------------------------------
# ÉTAPE 5 — Test de la réplication
# -----------------------------------------------------------------------------
# Crée un volume de 1 Gio, y écrit un fichier via un pod, puis affiche les
# réplicas : tu dois en voir 2, sur deux nœuds différents.
test_replication() {
  export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_PATH}"
  local kc="k3s kubectl"
  command -v k3s >/dev/null 2>&1 || kc="kubectl"

  log "Création d'un PVC et d'un pod de test"
  $kc apply -f - <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: repl-test
spec:
  accessModes: [ReadWriteOnce]
  storageClassName: longhorn
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: Pod
metadata:
  name: repl-test
spec:
  containers:
    - name: writer
      image: busybox:1.36
      command: ["sh", "-c", "date > /data/hello.txt; sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: repl-test
EOF

  $kc wait --for=condition=Ready pod/repl-test --timeout=300s
  log "Contenu écrit dans le volume :"
  $kc exec repl-test -- cat /data/hello.txt

  log "Réplicas Longhorn (colonne NODE : deux nœuds différents attendus) :"
  $kc -n longhorn-system get replicas.longhorn.io -o wide

  cat <<'EOF'

Nettoyage du test :
  kubectl delete pod/repl-test pvc/repl-test
EOF
}

# -----------------------------------------------------------------------------
# Contrôle — état du control plane etcd
# -----------------------------------------------------------------------------
# À lancer sur n'importe quel serveur. Vérifie que les 3 membres etcd sont là
# (tolérance à 1 panne) et liste les snapshots de sauvegarde disponibles.
status() {
  export KUBECONFIG="${KUBECONFIG:-$KUBECONFIG_PATH}"
  local kc="k3s kubectl"
  command -v k3s >/dev/null 2>&1 || kc="kubectl"

  log "Nœuds du cluster"
  $kc get nodes -o wide

  local n
  n="$($kc get nodes -l node-role.kubernetes.io/etcd=true --no-headers | wc -l)"
  log "Membres etcd : $n"
  if [ "$n" -lt 3 ]; then
    warn "Moins de 3 membres etcd : aucune tolérance de panne."
  elif [ $((n % 2)) -eq 0 ]; then
    warn "Nombre PAIR de membres etcd : pas plus tolérant qu'avec $((n - 1)). Vise un nombre impair."
  else
    echo "OK : le cluster reste pilotable si $(((n - 1) / 2)) serveur(s) tombe(nt)."
  fi

  log "Snapshots etcd disponibles"
  k3s etcd-snapshot ls 2>/dev/null || warn "Liste des snapshots indisponible sur cette machine."
}

case "${1:-}" in
  prereqs)     prereqs ;;
  server)      server ;;
  server-join) server_join ;;
  agent)       agent ;;
  longhorn)    longhorn ;;
  test)        test_replication ;;
  status)      status ;;
  *)
    echo "Usage: $0 {prereqs|server|server-join|agent|longhorn|test|status}"
    echo "Voir l'en-tête du script pour le détail des étapes."
    exit 1
    ;;
esac
