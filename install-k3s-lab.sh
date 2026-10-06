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
#   Disque NVMe dédié à /var/lib/rancher (recommandé pour les membres etcd) :
#       sudo RANCHER_DEVICE=/dev/nvme0n1 ETCD_ONLY=1 K3S_URL=... K3S_TOKEN=... \
#            ./install-k3s-lab.sh server-join
#       Le disque est partitionné, formaté en ext4 et monté AVANT l'installation de
#       k3s. Étape seule : sudo RANCHER_DEVICE=/dev/nvme0n1 ./install-k3s-lab.sh nvme
#   kubectl en couleur (kubecolor), alias k et kns, complétion, namespace courant
#       dans le prompt (kube-ps1) : installés automatiquement sur les serveurs.
#       Relance seule : sudo ./install-k3s-lab.sh kubectl-setup
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
#   RANCHER_DEVICE (voir plus bas) monte pour toi un NVMe sur /var/lib/rancher.
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
#   RANCHER_DEVICE      disque à monter sur /var/lib/rancher, ex: /dev/nvme0n1
#                       (vide = on ne touche à aucun disque)
#   RANCHER_FORMAT      yes = autoriser le formatage d'un disque qui contient déjà
#                       des données (EFFACE tout). Inutile pour un disque vierge.
#   RANCHER_MIGRATE     1 = si k3s est déjà installé, copie /var/lib/rancher vers le
#                       nouveau disque (k3s est arrêté pendant l'opération)
#   KUBECOLOR           1 (défaut) = installer kubecolor et aliaser kubectl/k dessus ;
#                       0 = alias k=kubectl sans couleur
#   KUBE_PS1            1 (défaut) = installer kube-ps1 et afficher le namespace
#                       courant dans le prompt ; 0 = prompt inchangé
#   KUBE_PS1_VERSION    version de kube-ps1 à installer (défaut : v1.0.0)
#   SHELL_USERS         utilisateurs dont le shell est configuré pour kubectl
#                       (défaut : l'utilisateur de sudo et root)
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
RANCHER_DEVICE="${RANCHER_DEVICE:-}"
RANCHER_FORMAT="${RANCHER_FORMAT:-no}"
RANCHER_MIGRATE="${RANCHER_MIGRATE:-0}"
KUBECOLOR="${KUBECOLOR:-1}"
KUBE_PS1="${KUBE_PS1:-1}"
KUBE_PS1_VERSION="${KUBE_PS1_VERSION:-v1.0.0}"
KUBE_PS1_DIR="/usr/local/share/kube-ps1"
SHELL_USERS="${SHELL_USERS:-}"
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
# chiffrement et à la gestion des périphériques de bloc. kubectx fournit
# kubectx (changer de contexte) et kubens (changer de namespace par défaut).
# (Installés aussi sur la machine C : inoffensif, et pratique si elle change de rôle.)
prereqs() {
  need_root
  log "Installation des paquets requis (open-iscsi, nfs-common, kubectx, ...)"
  apt-get update -y
  apt-get install -y open-iscsi nfs-common cryptsetup dmsetup curl ca-certificates kubectx

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
  for _ in $(seq 1 60); do
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
# Disque dédié à /var/lib/rancher (NVMe) — étape « nvme »
# -----------------------------------------------------------------------------
# /var/lib/rancher contient TOUT l'état de k3s : base etcd, certificats, images
# containerd. Sur un nœud etcd il doit être sur un disque rapide (SSD/NVMe), pas
# sur l'eMMC ou la carte SD que les écritures d'etcd useraient.
#
# Actif quand RANCHER_DEVICE est défini (ex: /dev/nvme0n1). Le script :
#   1. crée une partition GPT unique et la formate en ext4 (étiquette « rancher »),
#      sauf si ce disque a déjà été préparé par ce script (il est alors réutilisé) ;
#   2. ajoute l'entrée /etc/fstab par UUID, avec « nofail » : la machine démarre
#      même si le disque est absent ;
#   3. pose une dépendance systemd (RequiresMountsFor) : k3s REFUSE de démarrer si
#      le disque n'est pas monté, au lieu de démarrer avec une base vide sur l'eMMC ;
#   4. active fstrim.timer (nettoyage périodique du SSD).
#
# SÉCURITÉ : le formatage EFFACE le disque. Si /dev/... contient déjà des données
# (partition ou système de fichiers non préparé par ce script), il faut confirmer
# avec RANCHER_FORMAT=yes. Un disque monté (système, /home...) est toujours refusé.
setup_rancher_disk() {
  [ -n "$RANCHER_DEVICE" ] || return 0
  need_root
  local dev="$RANCHER_DEVICE" mnt="/var/lib/rancher" part uuid ts tmpm svc

  [ -b "$dev" ] || die "RANCHER_DEVICE : $dev n'est pas un périphérique bloc."

  if mountpoint -q "$mnt"; then
    log "$mnt est déjà un point de montage ($(findmnt -no SOURCE "$mnt")) : rien à formater."
  else
    # Disque déjà préparé par ce script ? (partition étiquetée « rancher »)
    part="$(lsblk -lnpo NAME,LABEL "$dev" | awk '$2=="rancher"{print $1; exit}')"

    if [ -z "$part" ]; then
      if lsblk -lnpo MOUNTPOINT "$dev" | grep -q .; then
        die "$dev (ou une de ses partitions) est monté : refus de le formater."
      fi
      if blkid -p "$dev" >/dev/null 2>&1 || [ "$(lsblk -lnpo TYPE "$dev" | grep -c part)" -gt 0 ]; then
        [ "$RANCHER_FORMAT" = "yes" ] \
          || die "$dev contient déjà des données ou une table de partitions. Vérifie avec 'lsblk -f', puis relance avec RANCHER_FORMAT=yes pour l'EFFACER."
      fi
      log "Partitionnement de $dev (GPT, 1 partition) puis formatage ext4"
      printf 'label: gpt\n,,L\n' | sfdisk --quiet --wipe always --wipe-partitions always "$dev"
      blockdev --rereadpt "$dev" 2>/dev/null || true
      udevadm settle 2>/dev/null || sleep 2
      # Attente (jusqu'à 10 s) que le noyau crée le fichier de la nouvelle partition
      part=""
      for _ in $(seq 1 20); do
        part="$(lsblk -lnpo NAME,TYPE "$dev" | awk '$2=="part"{print $1; exit}')"
        if [ -n "$part" ] && [ -b "$part" ]; then break; fi
        sleep 0.5
      done
      { [ -n "$part" ] && [ -b "$part" ]; } || die "Partition créée introuvable sur $dev."
      mkfs.ext4 -q -m 1 -L rancher "$part"
    else
      log "Partition $part déjà préparée (étiquette rancher) : réutilisée."
    fi

    uuid="$(blkid -s UUID -o value "$part")"
    [ -n "$uuid" ] || die "UUID de $part introuvable."

    if grep -qE "[[:space:]]${mnt}[[:space:]]" /etc/fstab; then
      grep -qF "$uuid" /etc/fstab \
        || die "/etc/fstab contient déjà une entrée pour $mnt avec un autre UUID : corrige-la à la main."
    else
      printf 'UUID=%s %s ext4 defaults,noatime,nofail,x-systemd.device-timeout=10s 0 2\n' "$uuid" "$mnt" >> /etc/fstab
      log "Entrée ajoutée à /etc/fstab"
    fi

    mkdir -p "$mnt"
    # Données déjà présentes sur l'ancien disque (k3s déjà installé) : migration
    if [ -n "$(ls -A "$mnt" 2>/dev/null)" ]; then
      [ "$RANCHER_MIGRATE" = "1" ] \
        || die "$mnt n'est pas vide (k3s déjà installé ?). Relance avec RANCHER_MIGRATE=1 pour copier les données sur le nouveau disque."
      command -v rsync >/dev/null 2>&1 || die "rsync est requis pour la migration (apt install rsync)."
      log "Migration des données de $mnt vers $part (k3s arrêté)"
      for svc in k3s k3s-agent; do
        systemctl stop "$svc" 2>/dev/null || true
      done
      tmpm="$(mktemp -d)"
      mount "$part" "$tmpm"
      rsync -aHAX "$mnt/" "$tmpm/"
      umount "$tmpm"
      rmdir "$tmpm"
      ts="$(date +%Y%m%d%H%M%S)"
      mv "$mnt" "$mnt.old-$ts"
      mkdir -p "$mnt"
      log "Anciennes données conservées dans $mnt.old-$ts : supprime-les après vérification."
    fi

    systemctl daemon-reload
    mount "$mnt"
  fi

  mountpoint -q "$mnt" || die "$mnt n'est pas monté : abandon."
  findmnt "$mnt"

  # k3s ne démarre que si le disque est monté
  for svc in k3s k3s-agent; do
    mkdir -p "/etc/systemd/system/${svc}.service.d"
    printf '[Unit]\nRequiresMountsFor=%s\n' "$mnt" > "/etc/systemd/system/${svc}.service.d/10-rancher-mount.conf"
  done
  systemctl daemon-reload
  systemctl enable --now fstrim.timer 2>/dev/null || warn "fstrim.timer indisponible."
}

# -----------------------------------------------------------------------------
# kubectl : couleur (kubecolor), alias k et complétion automatique
# -----------------------------------------------------------------------------
# kubecolor appelle kubectl et colorise sa sortie. Il est installé depuis le
# paquet .deb officiel du projet (amd64 ou arm64).
#
# POURQUOI LA COMPLÉTION DISPARAÎT AVEC UN ALIAS : bash attache la complétion au
# NOM de la commande. kubectl a la sienne (fonction __start_kubectl), mais pas
# « kubecolor » ni l'alias « k ». On leur rattache donc explicitement la même
# fonction avec « complete -o default -F __start_kubectl ... », APRÈS avoir chargé
# la complétion de kubectl.
install_kubecolor() {
  if command -v kubecolor >/dev/null 2>&1; then
    return 0
  fi
  local arch ver deb tmp
  arch="$(dpkg --print-architecture)"
  case "$arch" in
    amd64|arm64) ;;
    *) warn "kubecolor : pas de paquet .deb pour l'architecture $arch."; return 1 ;;
  esac
  log "Installation de kubecolor"
  ver="$(curl -fsSL https://kubecolor.github.io/packages/deb/version | tr -d '[:space:]')" \
    || { warn "kubecolor : version introuvable (réseau ?)."; return 1; }
  deb="kubecolor_${ver}_${arch}.deb"
  tmp="$(mktemp -d)"
  if curl -fsSL "https://kubecolor.github.io/packages/deb/pool/main/k/kubecolor/${deb}" -o "$tmp/$deb" \
     && dpkg -i "$tmp/$deb"; then
    rm -rf "$tmp"
    return 0
  fi
  rm -rf "$tmp"
  warn "kubecolor : installation impossible, kubectl reste sans couleur."
  return 1
}

# kube-ps1 (github.com/jonmosco/kube-ps1) affiche le contexte et le namespace
# courants dans le prompt. Il n'est pas packagé dans Debian : c'est un seul
# script shell, téléchargé dans une version fixée (KUBE_PS1_VERSION) pour que
# tous les nœuds aient le même. Il ne relance kubectl que si le kubeconfig a été
# modifié (par kubens, par exemple) : le prompt reste instantané.
install_kube_ps1() {
  if [ -r "$KUBE_PS1_DIR/kube-ps1.sh" ] \
     && [ "$(cat "$KUBE_PS1_DIR/VERSION" 2>/dev/null)" = "$KUBE_PS1_VERSION" ]; then
    return 0
  fi
  local tmp
  log "Installation de kube-ps1 ${KUBE_PS1_VERSION}"
  tmp="$(mktemp)"
  if curl -fsSL "https://raw.githubusercontent.com/jonmosco/kube-ps1/${KUBE_PS1_VERSION}/kube-ps1.sh" -o "$tmp" \
     && [ -s "$tmp" ]; then
    mkdir -p "$KUBE_PS1_DIR"
    install -m 644 "$tmp" "$KUBE_PS1_DIR/kube-ps1.sh"
    echo "$KUBE_PS1_VERSION" > "$KUBE_PS1_DIR/VERSION"
    rm -f "$tmp"
    return 0
  fi
  rm -f "$tmp"
  warn "kube-ps1 : téléchargement impossible, le prompt reste inchangé."
  return 1
}

# Écrit ~/.bash_kubectl : alias (k, kns), complétion et prompt (chargé depuis ~/.bashrc)
write_kubectl_shell() {
  local file="$1" color="$2" ps1="${3:-0}"
  {
    echo "# ~/.bash_kubectl — kubectl : couleur, alias k/kns, complétion, prompt (géré par install-k3s-lab.sh)"
    echo "LAB_KUBECOLOR=${color}"
    echo "LAB_KUBE_PS1=${ps1}"
    echo "LAB_KUBE_PS1_SCRIPT=${KUBE_PS1_DIR}/kube-ps1.sh"
    echo "LAB_K3S_KUBECONFIG=${KUBECONFIG_PATH}"
  } > "$file"
  cat >> "$file" <<'EOF'

[[ $- == *i* ]] || return 0

# Retire d'éventuels alias k/kubectl : un alias empêche de définir une fonction du même nom
unalias k kubectl 2>/dev/null || true

if command -v kubectl >/dev/null 2>&1; then
  # Charge bash-completion si ce shell ne l'a pas fait (le .bashrc de root, par ex.)
  if ! type _init_completion >/dev/null 2>&1 && [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  fi
  # Fonction __start_kubectl (déjà fournie par /etc/bash_completion.d/kubectl si présent)
  if ! type __start_kubectl >/dev/null 2>&1; then
    source <(kubectl completion bash 2>/dev/null)
  fi

  if [ "${LAB_KUBECOLOR:-1}" = "1" ] && command -v kubecolor >/dev/null 2>&1; then
    # kubecolor colorise la sortie de kubectl. Pendant la complétion, kubectl est
    # rappelé avec « __complete » : si kubecolor colorise CETTE réponse, les codes
    # couleur polluent le résultat et bash affiche « ((: 4 : erreur de syntaxe ».
    # On passe donc par des fonctions (et non des alias) qui envoient la complétion
    # directement au vrai kubectl et tout le reste à kubecolor.
    __lab_kc() {
      if [ "${1:-}" = "__complete" ] || [ "${1:-}" = "__completeNoDesc" ]; then
        command kubectl "$@"
      else
        command kubecolor "$@"
      fi
    }
    kubectl() { __lab_kc "$@"; }
    k() { __lab_kc "$@"; }
  else
    alias k=kubectl
  fi
  complete -o default -F __start_kubectl kubectl
  complete -o default -F __start_kubectl k
fi

# kns = kubens (changer de namespace par défaut). bash-completion ne charge la
# complétion qu'à la demande, d'après le nom de la commande : « kns » n'a pas de
# fichier, on charge donc celui de kubens puis on le rattache à l'alias.
if command -v kubens >/dev/null 2>&1; then
  alias kns=kubens
  if ! type _kube_namespaces >/dev/null 2>&1 && [ -f /usr/share/bash-completion/completions/kubens.bash ]; then
    . /usr/share/bash-completion/completions/kubens.bash
  fi
  if type _kube_namespaces >/dev/null 2>&1; then
    complete -F _kube_namespaces kns
  fi
fi

# Prompt : namespace courant via kube-ps1, ex. « (⎈|kube-system) user@hôte:~$ »
# Réglages modifiables en les définissant dans ~/.bashrc AVANT la ligne qui
# charge ce fichier (voir les variables KUBE_PS1_* de kube-ps1). Désactivation
# temporaire : kubeoff ; réactivation : kubeon.
# Avec Starship (étape shell de bootstrap-node.sh), le prompt est reconstruit à
# chaque commande et effacerait kube-ps1 : c'est alors le module kubernetes de
# Starship qui affiche le contexte et le namespace.
if [ "${LAB_KUBE_PS1:-0}" = "1" ] && [ -r "$LAB_KUBE_PS1_SCRIPT" ] && command -v kubectl >/dev/null 2>&1 \
   && ! command -v starship >/dev/null 2>&1; then
  # kube-ps1 ne relit la config que si le fichier kubeconfig change, et doit donc
  # le trouver. root n'a pas de ~/.kube/config : kubectl (k3s) lit alors
  # /etc/rancher/k3s/k3s.yaml, on l'indique explicitement.
  if [ -z "${KUBECONFIG:-}" ] && [ ! -r "$HOME/.kube/config" ] && [ -r "$LAB_K3S_KUBECONFIG" ]; then
    export KUBECONFIG="$LAB_K3S_KUBECONFIG"
  fi
  # Le vrai binaire, pas la fonction kubectl ci-dessus (kubecolor) : pas de
  # codes couleur dans le prompt.
  KUBE_PS1_BINARY="$(type -P kubectl)"
  # k3s n'a qu'un contexte, nommé « default » : on n'affiche que le namespace.
  # Avec plusieurs clusters (kubectx) : KUBE_PS1_CONTEXT_ENABLE=true.
  : "${KUBE_PS1_CONTEXT_ENABLE:=false}"
  : "${KUBE_PS1_SEPARATOR:=|}"
  # Sans namespace enregistré, kubectl utilise « default » : on l'affiche.
  __lab_kube_ps1_ns() {
    if [ "$1" = "N/A" ]; then echo default; else echo "$1"; fi
  }
  : "${KUBE_PS1_NAMESPACE_FUNCTION:=__lab_kube_ps1_ns}"
  . "$LAB_KUBE_PS1_SCRIPT"
  case "$PS1" in
    *kube_ps1*) ;;
    *) PS1='$(kube_ps1) '"$PS1" ;;
  esac
fi
EOF
}

setup_kubectl_shell() {
  need_root
  if ! command -v kubectl >/dev/null 2>&1; then
    warn "kubectl introuvable : k3s est-il installé sur cette machine ?"
    return 0
  fi
  local users u home grp tmp
  if [ "$KUBECOLOR" = "1" ]; then
    install_kubecolor || true
  fi
  local ps1=0
  if [ "$KUBE_PS1" = "1" ] && install_kube_ps1; then
    ps1=1
  fi

  # Complétion système (fichier statique : démarrage de shell plus rapide)
  tmp="$(mktemp)"
  if kubectl completion bash > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mkdir -p /etc/bash_completion.d
    install -m 644 "$tmp" /etc/bash_completion.d/kubectl
  fi
  rm -f "$tmp"

  users="${SHELL_USERS:-}"
  if [ -z "$users" ]; then
    users="root"
    if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != "root" ]; then
      users="$SUDO_USER root"
    fi
  fi
  for u in $users; do
    if ! id "$u" >/dev/null 2>&1; then
      warn "Utilisateur inconnu pour la config kubectl : $u"
      continue
    fi
    home="$(getent passwd "$u" | cut -d: -f6)"
    grp="$(id -gn "$u")"
    write_kubectl_shell "$home/.bash_kubectl" "$KUBECOLOR" "$ps1"
    touch "$home/.bashrc"
    if ! grep -qF '.bash_kubectl' "$home/.bashrc"; then
      printf '\n# kubectl : couleur, alias k/kns, complétion, prompt\n[ -f "$HOME/.bash_kubectl" ] && . "$HOME/.bash_kubectl"\n' >> "$home/.bashrc"
    fi
    chown "$u:$grp" "$home/.bash_kubectl" "$home/.bashrc"
  done
  log "kubectl : alias k/kns, complétion et prompt configurés (ouvre un nouveau shell ou : source ~/.bashrc)"
}

# -----------------------------------------------------------------------------
# ÉTAPE 2 — Premier serveur (machine A) : crée le cluster etcd
# -----------------------------------------------------------------------------
server() {
  need_root
  prereqs
  setup_rancher_disk
  log "Installation du 1er serveur k3s (etcd embarqué)"
  write_k3s_config init
  install_k3s_server
  setup_kubeconfig
  setup_kubectl_shell

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
  setup_rancher_disk
  log "Ajout de ce serveur au cluster (membre etcd + control plane)"
  write_k3s_config join
  install_k3s_server
  if [ "$ETCD_ONLY" != "1" ]; then
    setup_kubeconfig
    setup_kubectl_shell
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
  setup_rancher_disk
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
  nvme)
    need_root
    [ -n "$RANCHER_DEVICE" ] || die "RANCHER_DEVICE manquant (ex: sudo RANCHER_DEVICE=/dev/nvme0n1 $0 nvme)"
    setup_rancher_disk
    ;;
  kubectl-setup) setup_kubectl_shell ;;
  longhorn)    longhorn ;;
  test)        test_replication ;;
  status)      status ;;
  *)
    echo "Usage: $0 {prereqs|server|server-join|agent|nvme|kubectl-setup|longhorn|test|status}"
    echo "Voir l'en-tête du script pour le détail des étapes."
    exit 1
    ;;
esac