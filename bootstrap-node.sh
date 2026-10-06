#!/usr/bin/env bash
# =============================================================================
# bootstrap-node.sh — Préparer une machine Debian 12 ou 13 (amd64) pour le lab
# =============================================================================
#
# À lancer sur CHAQUE machine (nas1, nas2, nas3), en root. Le script est
# IDEMPOTENT : tu peux le relancer sans casser ce qui est déjà en place.
#
# CE QU'IL FAIT
#   packages   Paquets de base (sudo, git, vim, chrony...). chrony synchronise
#              l'heure : indispensable pour etcd et les certificats Kubernetes.
#   base       Reprend de façon compatible Debian 13 les réglages utiles du rôle
#              Ansible base : outils d'exploitation, bash, Git, pager, cron et
#              permissions système. Aucun mot de passe root n'est défini.
#   dev        Installe les outils de développement interactifs (fzf, zoxide,
#              direnv, bat, fd) pour l'utilisateur d'administration.
#   user       Crée l'utilisateur d'administration, membre du groupe sudo, et
#              installe ta clé publique SSH.
#   ssh        Durcit sshd (root interdit, mot de passe interdit SI une clé est
#              installée) et affiche le bloc à copier dans ton ~/.ssh/config.
#   shell      Installe et configure tmux et le prompt Starship (couleur propre à
#              chaque machine, Git et Kubernetes) pour l'utilisateur et root.
#              Debian 13 : paquets natifs. Debian 12 : tmux 3.5a des backports et
#              Starship officiel, depuis le dossier bundle (voir « download »).
#   docker     Installe le daemon Docker (dépôt officiel, amd64 ou arm64 détecté
#              automatiquement) avec rotation des logs.
#   kubectl    (à la demande) Installe kubectl, kubecolor et kubectx, installe le
#              kubeconfig de l'utilisateur et configure alias (k, kns) et
#              complétion. Sur un nœud k3s : kubeconfig local. Sur ton poste (WSL,
#              portable) : kubeconfig copié par SSH depuis un serveur.
#   download   (à la demande, sans root) Télécharge dans le dossier bundle ce qui
#              n'est pas dans les dépôts Debian : kubectl, kubecolor, Starship,
#              tmux 3.5a pour Debian 12, et les plugins tmux (TPM, resurrect,
#              continuum). Les étapes shell et kubectl utilisent ce dossier
#              s'il est rempli : copie-le avec le script sur une machine sans
#              internet (airgap). Supprime-le pour reprendre les dernières versions.
#
# k3s lui-même s'installe avec install-k3s-lab.sh, qui ne touche pas à
# l'environnement de la machine.
#
# UTILISATION
#   Tout préparer (sans installer k3s) :
#     sudo ADMIN_USER=admin SSH_PUBKEY_FILE=/tmp/id_ed25519.pub ./bootstrap-node.sh
#   Une seule étape :
#     sudo ADMIN_USER=admin ./bootstrap-node.sh shell
#   Appliquer la base système seule :
#     sudo ./bootstrap-node.sh base
#   Préparer le poste de développement de l'utilisateur admin :
#     sudo ADMIN_USER=admin ./bootstrap-node.sh dev
#   Préparer les binaires sur une machine connectée (avant un airgap) :
#     ./bootstrap-node.sh download
#   Après install-k3s-lab.sh, sur chaque nœud k3s :
#     sudo ADMIN_USER=admin ./bootstrap-node.sh kubectl
#   Piloter le cluster depuis ton poste (dans un vrai terminal : ssh et sudo
#   peuvent demander un mot de passe) :
#     sudo DEV_USER=$USER KUBECONFIG_SOURCE=nas1 ./bootstrap-node.sh kubectl
#
# VARIABLES
#   ADMIN_USER        utilisateur d'administration à créer/configurer, ex: admin
#                     (défaut : l'utilisateur qui a lancé sudo). Les étapes shell
#                     et kubectl configurent CET utilisateur ET root ; le script
#                     refuse de continuer s'il ne sait pas quel utilisateur viser
#                     (script lancé directement en root, sans sudo ni ADMIN_USER).
#   SSH_PUBKEY_FILE   fichier de clé publique à autoriser
#   SSH_PUBKEY        ou la clé publique elle-même (une ligne)
#   SUDO_NOPASSWD     1 = sudo sans mot de passe (pratique en lab ; si la clé SSH
#                     est volée, l'accès root l'est aussi). Défaut 0 : le script te
#                     demande un mot de passe pour le nouvel utilisateur.
#   HARDEN_SSH        1 (défaut) = durcir sshd ; 0 = ne pas toucher à sshd
#   SSH_ALLOW_USERS   restreindre SSH à ces utilisateurs (vide = pas de restriction).
#                     Attention : ne l'active que si tu te connectes déjà avec eux.
#   TMUX_AUTOSTART    1 = ouvre/reprend automatiquement une session tmux à la
#                     connexion SSH. Défaut 0.
#   HOST_COLOR        couleur 0-255 du nom de machine (défaut : dérivée du hostname)
#   INSTALL_DOCKER    1 (défaut) ou 0 (ex: pour économiser la RAM sur nas3)
#   DOCKER_SOURCE     official (défaut, dépôt Docker) | debian (paquet docker.io)
#   DOCKER_DATA_ROOT  dossier des données Docker (ext4/xfs), ex: /mnt/nvme/docker
#   BASE_GIT_CREDENTIAL_CACHE_TIMEOUT  durée en secondes du cache Git (défaut 900,
#                     0 = ne pas configurer le cache).
#   DEV_USER          utilisateur à configurer aux étapes dev et kubectl, s'il
#                     diffère de ADMIN_USER (défaut : ADMIN_USER).
#   BUNDLE_DIR        dossier des binaires téléchargés (défaut : bundle/ à côté
#                     du script)
#   KUBECTL_VERSION   version de kubectl, ex: v1.33.4 (défaut : la stable actuelle).
#                     Garde au plus une version mineure d'écart avec le cluster.
#   KUBECOLOR_VERSION version de kubecolor, ex: v0.8.0 (défaut : la dernière)
#   STARSHIP_VERSION  version de Starship pour Debian 12, ex: v1.26.0 (défaut :
#                     la dernière)
#   KUBECONFIG_SOURCE serveur k3s d'où copier le kubeconfig par SSH, ex: nas1 ou
#                     admin@192.168.1.10 (lit ~/.kube/config de l'utilisateur
#                     distant, installé là par l'étape kubectl). Vide = kubeconfig
#                     local de k3s s'il existe.
#   K3S_API           adresse de l'API à mettre dans ce kubeconfig, ex:
#                     k3s.lab.local (défaut : l'adresse SSH de KUBECONFIG_SOURCE)
#   KUBE_CONTEXT      nom du contexte kubectl créé (défaut : k3s-lab)
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Utilisateur qui a lancé sudo (vide si le script est lancé directement en root)
SUDO_REAL_USER="${SUDO_USER:-}"
[ "$SUDO_REAL_USER" = "root" ] && SUDO_REAL_USER=""
ADMIN_USER="${ADMIN_USER:-$SUDO_REAL_USER}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
SSH_PUBKEY_FILE="${SSH_PUBKEY_FILE:-}"
SUDO_NOPASSWD="${SUDO_NOPASSWD:-0}"
HARDEN_SSH="${HARDEN_SSH:-1}"
SSH_ALLOW_USERS="${SSH_ALLOW_USERS:-}"
TMUX_AUTOSTART="${TMUX_AUTOSTART:-0}"
HOST_COLOR="${HOST_COLOR:-}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
DOCKER_SOURCE="${DOCKER_SOURCE:-official}"
DOCKER_DATA_ROOT="${DOCKER_DATA_ROOT:-}"
BASE_GIT_CREDENTIAL_CACHE_TIMEOUT="${BASE_GIT_CREDENTIAL_CACHE_TIMEOUT:-900}"
DEV_USER="${DEV_USER:-$ADMIN_USER}"
BUNDLE_DIR="${BUNDLE_DIR:-$(dirname "$(readlink -f "$0")")/bundle}"
KUBECTL_VERSION="${KUBECTL_VERSION:-}"
KUBECOLOR_VERSION="${KUBECOLOR_VERSION:-}"
STARSHIP_VERSION="${STARSHIP_VERSION:-}"
# Plugins tmux (dépôts GitHub) : doivent correspondre aux « @plugin » de write_tmux_conf
TMUX_PLUGINS="tmux-plugins/tpm tmux-plugins/tmux-resurrect tmux-plugins/tmux-continuum"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
KUBECONFIG_SOURCE="${KUBECONFIG_SOURCE:-}"
K3S_API="${K3S_API:-}"
KUBE_CONTEXT="${KUBE_CONTEXT:-k3s-lab}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mATTENTION: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Lance ce script en root (sudo)."
}

get_home() {
  getent passwd "$1" | cut -d: -f6
}

# ADMIN_USER renseigné et différent de root (il peut ne pas encore exister :
# l'étape user le crée).
require_admin_user() {
  [ -n "$ADMIN_USER" ] \
    || die "Utilisateur à configurer inconnu : lance le script avec sudo depuis ton compte, ou indique ADMIN_USER=... (ex: sudo ADMIN_USER=admin $0)."
  [ "$ADMIN_USER" != "root" ] || die "ADMIN_USER doit être un utilisateur normal, pas root."
}

# ADMIN_USER renseigné ET existant (étapes qui écrivent dans son dossier)
require_existing_admin_user() {
  require_admin_user
  id "$ADMIN_USER" >/dev/null 2>&1 \
    || die "Utilisateur $ADMIN_USER introuvable : crée-le d'abord (étape user)."
  log "Configuration pour l'utilisateur $ADMIN_USER et pour root"
}

require_dev_user() {
  [ -n "$DEV_USER" ] \
    || die "Utilisateur à configurer inconnu : lance le script avec sudo depuis ton compte, ou indique DEV_USER=... ou ADMIN_USER=..."
  [ "$DEV_USER" != "root" ] || die "DEV_USER doit être un utilisateur normal."
  id "$DEV_USER" >/dev/null 2>&1 || die "Utilisateur DEV_USER introuvable : $DEV_USER"
  log "Configuration pour l'utilisateur $DEV_USER"
}

check_os() {
  local arch
  arch="$(dpkg --print-architecture)"
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Système : ${PRETTY_NAME:-inconnu} — architecture : $arch — hôte : $(hostname)"
  if [ "${ID:-}" != "debian" ]; then
    warn "Ce script vise Debian ; système détecté : ${ID:-?}."
  elif [ "${VERSION_ID:-}" != "12" ] && [ "${VERSION_ID:-}" != "13" ]; then
    warn "Ce script est prévu pour Debian 12 ou 13 ; version détectée : ${VERSION_ID:-?}."
  fi
  if [ "$arch" != "amd64" ]; then
    warn "Seule l'architecture amd64 est prévue ; détectée : $arch."
  fi
}

# Version majeure de Debian (12, 13...), vide si inconnue
debian_major() {
  # shellcheck disable=SC1091
  (. /etc/os-release && echo "${VERSION_ID:-}")
}

# -----------------------------------------------------------------------------
# packages — base du système
# -----------------------------------------------------------------------------
step_packages() {
  log "Installation des paquets de base"
  apt-get update -y
  apt-get install -y sudo openssh-server curl ca-certificates gnupg xz-utils git vim-nox \
    htop jq rsync chrony bash-completion \
    thefuck command-not-found most apt-file xclip xsel wl-clipboard ncurses-term
  systemctl enable --now chrony
}

base() {
  local pkg tmp bashrc marker_begin marker_end key value editor_bin candidate
  local -a requested available

  systemctl enable --now cron

  # Équivalent moderne de la configuration Git du rôle, sans imposer une
  # identité : celle-ci doit rester propre à chaque utilisateur/projet.
  git config --system core.whitespace 'trailing-space,space-before-tab,indent-with-non-tab'
  git config --system color.ui true
  git config --system tag.sort version:refname
  git config --system alias.a add
  git config --system alias.b 'branch -vv --all'
  git config --system alias.c commit
  git config --system alias.s status
  git config --system alias.p push
  git config --system alias.co checkout
  git config --system alias.d diff
  git config --system alias.l 'log --branches --remotes --graph'
  git config --system alias.lg "log --graph --pretty=tformat:%Cred%h%Creset\ %Cblue%d%Creset\ %s\ %Cgreen(%an%ar)%Creset"
  git config --system alias.st status
  git config --system alias.su 'submodule update --init --recursive'
  if [[ "$BASE_GIT_CREDENTIAL_CACHE_TIMEOUT" =~ ^[0-9]+$ ]] && [ "$BASE_GIT_CREDENTIAL_CACHE_TIMEOUT" -gt 0 ]; then
    git config --system credential.helper "cache --timeout=${BASE_GIT_CREDENTIAL_CACHE_TIMEOUT}"
  elif [ "$BASE_GIT_CREDENTIAL_CACHE_TIMEOUT" != "0" ]; then
    warn "BASE_GIT_CREDENTIAL_CACHE_TIMEOUT doit être un entier positif ou 0 ; cache Git non configuré."
  fi

  editor_bin=""
  for candidate in "$(readlink -f "$(command -v vim 2>/dev/null || true)")" \
    /usr/bin/vim.basic /usr/bin/vim.nox /usr/bin/vim.tiny; do
    if [ -n "$candidate" ] && update-alternatives --list editor 2>/dev/null | grep -qxF "$candidate"; then
      editor_bin="$candidate"
      break
    fi
  done
  if [ -n "$editor_bin" ]; then
    update-alternatives --set editor "$editor_bin" || warn "Impossible de sélectionner vim comme éditeur."
  else
    warn "Aucune variante Vim n'est enregistrée pour l'alternative editor."
  fi
  if command -v most >/dev/null 2>&1; then
    update-alternatives --set pager "$(command -v most)" || warn "Impossible de sélectionner most comme pager."
  fi
  if [ -f /etc/environment ]; then
    if grep -q '^PATH=' /etc/environment; then
      sed -i 's|^PATH=.*|PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin|' /etc/environment
    else
      printf '%s\n' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' >> /etc/environment
    fi
  fi

}

# -----------------------------------------------------------------------------
# dev — environnement interactif de développement pour un utilisateur
# -----------------------------------------------------------------------------
dev() {
  local home grp devrc bashrc tmp
  require_dev_user
  home="$(get_home "$DEV_USER")"
  grp="$(id -gn "$DEV_USER")"
  bashrc="$home/.bashrc"
  devrc="$home/.bash_dev"

  log "Installation de l'environnement de développement pour $DEV_USER"
  apt-get update -y
  apt-get install -y fzf zoxide direnv bat fd-find

  tmp="$(mktemp)"
  cat > "$tmp" <<'EOF'
# Outils de développement — géré par bootstrap-node.sh
# Chargé après ~/.bash_shell afin de préserver le prompt par hôte.

# Recherche floue : Ctrl-R (historique), Ctrl-T (fichiers), Alt-C (dossiers).
if command -v fzf >/dev/null 2>&1 && fzf --bash >/dev/null 2>&1; then
  eval "$(fzf --bash)"
fi

# Navigation rapide : z <répertoire>, zi <répertoire> (sélecteur fzf).
if command -v zoxide >/dev/null 2>&1; then
  eval "$(zoxide init bash)"
fi

# Variables propres au projet via .envrc ; le hook doit être chargé après les
# extensions qui manipulent PROMPT_COMMAND.
if command -v direnv >/dev/null 2>&1; then
  eval "$(direnv hook bash)"
fi

# Debian peut exposer bat sous le nom batcat.
if ! command -v bat >/dev/null 2>&1 && command -v batcat >/dev/null 2>&1; then
  alias bat='batcat'
fi
if ! command -v fd >/dev/null 2>&1 && command -v fdfind >/dev/null 2>&1; then
  alias fd='fdfind'
fi
EOF
  install -o "$DEV_USER" -g "$grp" -m 644 "$tmp" "$devrc"
  rm -f "$tmp"
  touch "$bashrc"
  if ! grep -qF '.bash_dev' "$bashrc"; then
    printf '\n# Outils de développement\n[ -f "$HOME/.bash_dev" ] && . "$HOME/.bash_dev"\n' >> "$bashrc"
  fi
  chown "$DEV_USER:$grp" "$bashrc"
  log "Configuration écrite dans $devrc"
  warn "Ouvre une nouvelle session pour activer fzf, zoxide et direnv."
}

# -----------------------------------------------------------------------------
# user — compte d'administration avec sudo + clé SSH
# -----------------------------------------------------------------------------
step_user() {
  require_admin_user
  local created=0 home grp key="" ak tmp
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    log "L'utilisateur $ADMIN_USER existe déjà"
  else
    log "Création de l'utilisateur $ADMIN_USER"
    adduser --disabled-password --gecos "" "$ADMIN_USER"
    created=1
  fi
  usermod -aG sudo "$ADMIN_USER"
  home="$(get_home "$ADMIN_USER")"
  grp="$(id -gn "$ADMIN_USER")"

  if [ -n "$SSH_PUBKEY_FILE" ]; then
    [ -f "$SSH_PUBKEY_FILE" ] || die "SSH_PUBKEY_FILE introuvable : $SSH_PUBKEY_FILE"
    key="$(head -n 1 "$SSH_PUBKEY_FILE")"
  elif [ -n "$SSH_PUBKEY" ]; then
    key="$SSH_PUBKEY"
  fi

  install -d -m 700 -o "$ADMIN_USER" -g "$grp" "$home/.ssh"
  ak="$home/.ssh/authorized_keys"
  touch "$ak"
  chmod 600 "$ak"
  chown "$ADMIN_USER:$grp" "$ak"

  if [ -n "$key" ]; then
    # On vérifie que la clé est valide AVANT de l'installer : une clé cassée
    # + mot de passe SSH désactivé = machine inaccessible.
    tmp="$(mktemp)"
    printf '%s\n' "$key" > "$tmp"
    if ! ssh-keygen -lf "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      die "La clé publique fournie n'est pas valide."
    fi
    rm -f "$tmp"
    if ! grep -qxF "$key" "$ak"; then
      printf '%s\n' "$key" >> "$ak"
      log "Clé SSH ajoutée à $ak"
    fi
  else
    warn "Aucune clé publique fournie (SSH_PUBKEY_FILE / SSH_PUBKEY)."
  fi

  if [ "$SUDO_NOPASSWD" = "1" ]; then
    local f="/etc/sudoers.d/90-lab-${ADMIN_USER//./_}"
    echo "$ADMIN_USER ALL=(ALL) NOPASSWD:ALL" > "$f"
    chmod 440 "$f"
    if ! visudo -cf "$f" >/dev/null; then
      rm -f "$f"
      die "Règle sudoers invalide, supprimée."
    fi
    log "sudo sans mot de passe activé pour $ADMIN_USER"
  elif [ "$created" = "1" ]; then
    if [ -t 0 ]; then
      log "Définis le mot de passe de $ADMIN_USER (demandé par sudo)"
      passwd "$ADMIN_USER"
    else
      warn "Pas de terminal : définis le mot de passe avec 'passwd $ADMIN_USER', sinon sudo sera inutilisable."
    fi
  fi
}

# -----------------------------------------------------------------------------
# ssh — durcissement de sshd
# -----------------------------------------------------------------------------
step_ssh() {
  if [ "$HARDEN_SSH" != "1" ]; then
    log "Durcissement SSH ignoré (HARDEN_SSH=0)"
    return 0
  fi
  require_admin_user
  local home ak conf="/etc/ssh/sshd_config.d/00-lab-hardening.conf" sshd_bin ip
  home="$(get_home "$ADMIN_USER")"
  ak="$home/.ssh/authorized_keys"
  sshd_bin="$(command -v sshd || echo /usr/sbin/sshd)"
  mkdir -p /etc/ssh/sshd_config.d

  log "Durcissement de sshd ($conf)"
  {
    echo "# Géré par bootstrap-node.sh"
    echo "PermitRootLogin no"
    echo "PubkeyAuthentication yes"
    if [ -s "$ak" ]; then
      echo "PasswordAuthentication no"
      echo "KbdInteractiveAuthentication no"
    fi
    echo "X11Forwarding no"
    echo "MaxAuthTries 3"
    echo "LoginGraceTime 30"
    echo "ClientAliveInterval 60"
    echo "ClientAliveCountMax 3"
    if [ -n "$SSH_ALLOW_USERS" ]; then
      echo "AllowUsers $SSH_ALLOW_USERS"
    fi
  } > "$conf"

  if [ ! -s "$ak" ]; then
    warn "Aucune clé pour $ADMIN_USER : l'authentification par mot de passe reste ACTIVE."
  fi

  if ! "$sshd_bin" -t; then
    rm -f "$conf"
    die "Configuration sshd invalide : fichier supprimé, rien n'a été appliqué."
  fi
  systemctl try-reload-or-restart ssh
  warn "Teste la connexion SSH depuis un 2e terminal AVANT de fermer cette session."

  ip="$(hostname -I | awk '{print $1}')"
  cat <<EOF

Bloc à ajouter dans ~/.ssh/config sur TON POSTE :

Host $(hostname)
    HostName ${ip}
    User ${ADMIN_USER}
    IdentityFile ~/.ssh/id_ed25519
    ServerAliveInterval 30
EOF
}

# -----------------------------------------------------------------------------
# shell — tmux + prompt
# -----------------------------------------------------------------------------
write_tmux_conf() {
  local file="$1" col="$2"
  cat > "$file" <<EOF
# ~/.tmux.conf — géré par bootstrap-node.sh
# Base : configuration de la formation (tmux.conf du dépôt), complétée par les
# réglages du lab (presse-papiers, Alt+flèches, | et -, vi, plugins).
# En cas de conflit, la valeur de la formation est conservée.

# ------------------------------------------------------------
# Général
# ------------------------------------------------------------
set -g mouse on
set -g history-limit 50000
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 0
set -g focus-events on
setw -g mode-keys vi

# True color, et presse-papiers OSC 52 annoncé pour les terminaux courants
set -g default-terminal "tmux-256color"
set -as terminal-features ",xterm-256color:RGB"
set -as terminal-features ",xterm*:RGB:clipboard"
set -as terminal-features ",screen*:RGB:clipboard"
set -as terminal-features ",tmux*:RGB:clipboard"

# ------------------------------------------------------------
# Souris : la molette fait défiler l'historique (entre en mode copie)
# ------------------------------------------------------------
bind -n WheelUpPane if-shell -F -t = "#{mouse_any_flag}" "send-keys -M" "if -Ft= '#{pane_in_mode}' 'send-keys -M' 'select-pane -t=; copy-mode -e; send-keys -M'"
bind -n WheelDownPane select-pane -t= \; send-keys -M

# ------------------------------------------------------------
# Presse-papiers
# ------------------------------------------------------------
# « on » et non « external » : tmux accepte aussi les copies faites PAR les
# programmes du panneau (séquence OSC 52), puis les transmet au terminal. C'est
# indispensable quand tmux est imbriqué (tmux local -> ssh -> tmux du nœud ->
# Claude) : avec « external », le tmux local jette la copie qui remonte du nœud.
set -s set-clipboard on
# Les terminaux sans OSC 52 (GNOME Terminal, Terminator et autres terminaux VTE)
# ignorent cette séquence : on écrit donc AUSSI dans le presse-papiers système
# quand une session graphique est accessible (wl-copy, xclip, xsel ou Windows
# sous WSL). Sur un nœud sans écran, lab-clip-copy ne fait rien.
set -s copy-command '/usr/local/bin/lab-clip-copy'
set-hook -g pane-set-clipboard 'run-shell -b "tmux save-buffer - | /usr/local/bin/lab-clip-copy"'
bind -T copy-mode-vi v send -X begin-selection
bind -T copy-mode-vi y send -X copy-pipe-and-cancel
bind -T copy-mode-vi Enter send -X copy-pipe-and-cancel
bind -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel \; display-message "Copié"

# ------------------------------------------------------------
# Panneaux et fenêtres
# ------------------------------------------------------------
# Changer de panneau : prefix + h/j/k/l, ou Alt + flèches sans prefix
bind h select-pane -L
bind j select-pane -D
bind k select-pane -U
bind l select-pane -R
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# Garder le dossier courant : " et % (standard), | et - (plus intuitifs)
bind c new-window -c "#{pane_current_path}"
bind '"' split-window -v -c "#{pane_current_path}"
bind % split-window -h -c "#{pane_current_path}"
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# Recharger la configuration : prefix + r
bind r source-file ~/.tmux.conf \; display-message "tmux config reloaded"

# Nom de fenêtre = dossier courant
setw -g automatic-rename on
setw -g automatic-rename-format '#{b:pane_current_path}'

# Titre en haut de chaque panneau
set -g pane-border-status top
set -g pane-border-format " #{pane_index} #{pane_title} "
set -g pane-border-style "fg=#45475a"
set -g pane-active-border-style "fg=#89b4fa"

# Activité dans une autre fenêtre : marquée dans la barre, sans message
setw -g monitor-activity on
set -g visual-activity off

# ------------------------------------------------------------
# Barre d'état
# ------------------------------------------------------------
set -g status on
set -g status-position bottom
set -g status-interval 1
set -g status-style bg=yellow,bold
# Nom de la machine dans sa couleur propre, puis nom de la session
set -g status-left-length 40
set -g status-left "#[bg=colour${col},fg=colour235,bold] #H #[default] #S "
set -g status-right-length 80
set -g status-right " %Y-%m-%d %H:%M "
setw -g window-status-format " #I:#W "
setw -g window-status-current-format " [#I:#W] "
set -g message-style "bg=#313244,fg=#cdd6f4"
setw -g mode-style "bg=#45475a,fg=#f5e0dc"

# ------------------------------------------------------------
# Plugins gérés par TPM
# ------------------------------------------------------------
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'

# Resurrect : inclure le contenu visible des panes dans la sauvegarde
set -g @resurrect-capture-pane-contents 'on'

# Continuum : sauvegarde toutes les 5 minutes et restauration automatique
set -g @continuum-save-interval '5'
set -g @continuum-restore 'on'

# TPM doit rester à la fin du fichier
run '~/.tmux/plugins/tpm/tpm'
EOF
}

# Copie l'entrée standard dans le presse-papiers système, utilisé par tmux.
write_clip_helper() {
  cat > /usr/local/bin/lab-clip-copy <<'EOF'
#!/bin/sh
# lab-clip-copy — copie l'entrée standard dans le presse-papiers système
# (géré par bootstrap-node.sh, appelé par tmux à chaque copie).
# Sans session graphique (nœud en SSH), l'entrée est ignorée : tmux transmet de
# toute façon la copie au terminal par OSC 52.
# Les sorties sont redirigées : wl-copy et xclip restent en arrière-plan pour
# servir le presse-papiers, et tmux attendrait sinon leur fin.
if [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
  exec wl-copy >/dev/null 2>&1
elif [ -n "${DISPLAY:-}" ] && command -v xclip >/dev/null 2>&1; then
  exec xclip -selection clipboard >/dev/null 2>&1
elif [ -n "${DISPLAY:-}" ] && command -v xsel >/dev/null 2>&1; then
  exec xsel --clipboard --input >/dev/null 2>&1
elif grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null && command -v powershell.exe >/dev/null 2>&1; then
  # clip.exe abîme les accents : PowerShell lit l'entrée en UTF-8
  exec powershell.exe -NoProfile -Command \
    '[Console]::InputEncoding = [Text.Encoding]::UTF8; Set-Clipboard -Value ([Console]::In.ReadToEnd())' \
    >/dev/null 2>&1
else
  cat >/dev/null
fi
EOF
  chmod 755 /usr/local/bin/lab-clip-copy
}

write_vim_conf() {
  local file="$1" col="$2"

  [ -f "$file" ] && cp "$file" "${file}.bak.$(date +%F)"
  cat > "$file" <<EOF
" --- Base ---------------------------------------------------
set nocompatible              " Mode Vim pur (pas de compatibilité vi)
set encoding=utf-8            " Encodage interne UTF-8
set hidden                    " Permet de changer de buffer sans sauvegarder
set mouse=                    " Souris désactivée (la sélection du terminal reste utilisable)

" --- Affichage ----------------------------------------------
set relativenumber            " Numéros relatifs : la ligne du curseur affiche 0
set cursorline                " Surligne la ligne courante
set scrolloff=5               " Garde 5 lignes de contexte autour du curseur
set showcmd                   " Affiche la commande en cours de frappe
set ruler                     " Position du curseur en bas à droite
set laststatus=2              " Barre d'état toujours visible
set wildmenu                  " Complétion améliorée en mode commande

" --- Couleurs et syntaxe -----------------------------------
syntax on                     " Coloration syntaxique
filetype plugin indent on     " Détection du type de fichier + indentation adaptée
set t_Co=256                  " Terminal 256 couleurs
set background=dark           " Fond sombre
colorscheme desert            " Thème desert

" --- Indentation --------------------------------------------
set expandtab                 " Tabulation -> espaces
set tabstop=4                 " Largeur d'affichage d'une tabulation
set shiftwidth=4              " Largeur d'un niveau d'indentation
set softtabstop=4             " Backspace efface 4 espaces d'un coup
set autoindent                " Conserve l'indentation de la ligne précédente

" --- Recherche ----------------------------------------------
set incsearch                 " Recherche incrémentale (pendant la frappe)
set hlsearch                  " Surligne les résultats
set ignorecase                " Insensible à la casse...
set smartcase                 " ...sauf si la recherche contient une majuscule
nnoremap <silent> <Esc><Esc> :nohlsearch<CR>   " Double Echap = efface le surlignage

" --- Copier / coller ----------------------------------------
" Note : vim-nox est compilé SANS +clipboard, donc "+y ne marche pas.
" On passe par xclip (sudo apt install xclip) ; sous Wayland, remplacer par wl-copy / wl-paste.
set pastetoggle=<F2>          " F2 : mode paste (évite l'auto-indentation en collant du texte)
vnoremap <leader>y :w !xclip -selection clipboard<CR><CR>   " \y en visuel : copie vers le presse-papier système
nnoremap <leader>p :r !xclip -selection clipboard -o<CR>    " \p : colle le presse-papier système sous le curseur

" --- Caractères spéciaux ------------------------------------
set listchars=tab:»·,trail:·,eol:¬,nbsp:␣,extends:>,precedes:<
nnoremap <F3> :set list!<CR>  " F3 : affiche/masque tabs, espaces de fin, fins de ligne
nnoremap <leader>w :set wrap!<CR>   " \w : bascule le retour à la ligne

" --- Sudo à l'écriture --------------------------------------
cnoremap w!! w !sudo tee % >/dev/null<CR>:e!<CR>   " :w!! sauvegarde avec sudo (fichier ouvert sans droits)
command! W execute 'w !sudo tee % > /dev/null' <bar> edit!   " :W fait la même chose

" --- Confort ------------------------------------------------
set undofile                  " Historique d'annulation persistant
set undodir=~/.vim/undo//     " ...stocké ici
set backspace=indent,eol,start " Backspace fonctionne partout
set nobackup noswapfile       " Pas de fichiers ~ ni .swp (à retirer si tu préfères la sécurité)
set history=1000              " Historique de commandes plus long
set splitright splitbelow     " Les nouveaux splits s'ouvrent à droite / en bas
set virtualedit=block   " Permet de placer le curseur au-delà de la fin des lignes en mode bloc

" Supprimer les espaces de fin de ligne avec F4
nnoremap <F4> :%s/\s\+$//e<CR>:nohlsearch<CR>

EOF

}


write_starship_config() {
  local file="$1" col="$2"
  cat > "$file" <<'EOF'
# Géré par bootstrap-node.sh
"$schema" = 'https://starship.rs/config-schema.json'

add_newline = false
scan_timeout = 30
format = """
$username\
$hostname\
$directory\
$git_branch\
$git_status\
$kubernetes\
$line_break\
$character"""

[username]
show_always = true
format = '[$user]($style)@'
style_user = 'bold white'
style_root = 'bold red'

[hostname]
ssh_only = false
format = '[$hostname]($style):'
style = 'bold fg:__HOST_COLOR__'

[directory]
style = 'bold blue'
truncation_length = 4
truncate_to_repo = false

[git_branch]
format = '[$symbol$branch]($style) '
style = 'yellow'

[git_status]
style = 'yellow'

[kubernetes]
disabled = false
format = '[$symbol$context]($style) '
style = 'bold cyan'

[cmd_duration]
disabled = true

[status]
disabled = true

[character]
success_symbol = '[❯](bold green) '
error_symbol = '[❯](bold red) '
vimcmd_symbol = '[❮](bold green) '
EOF
  sed -i "s/__HOST_COLOR__/${col}/g" "$file"
}

write_bash_shell() {
  local file="$1" autostart="$2"
  {
    echo "# ~/.bash_shell — shell du lab (géré par bootstrap-node.sh)"
    echo "LAB_TMUX_AUTOSTART=${autostart}"
  } > "$file"
  cat >> "$file" <<'EOF'

# Historique
export HISTSIZE=50000
export HISTFILESIZE=100000
export HISTCONTROL=ignoreboth:erasedups
shopt -s histappend checkwinsize

# Alias
alias ll='ls -alFh --color=auto'
alias la='ls -A --color=auto'
alias ..='cd ..'
alias grep='grep --color=auto'
alias k='kubectl'
alias dps='docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Image}}"'

# Prompt Starship ; sa configuration est dans ~/.config/starship.toml.
if command -v starship >/dev/null 2>&1; then
  # Une ancienne ~/.bash_lab peut encore avoir ajouté __lab_prompt à
  # PROMPT_COMMAND dans une session existante. Starship doit en être l'unique
  # gestionnaire, sinon l'ancien prompt réécrit PS1 et affiche [exit N].
  unset -f __lab_prompt 2>/dev/null || true
  PROMPT_COMMAND=""
  eval "$(starship init bash)"
fi

# Ouvre ou reprend la session tmux « main » à la connexion SSH (si activé)
if [ "${LAB_TMUX_AUTOSTART:-0}" = "1" ] && [ -n "${SSH_CONNECTION:-}" ] \
   && [ -z "${TMUX:-}" ] && [[ $- == *i* ]] && command -v tmux >/dev/null 2>&1; then
  exec tmux new-session -A -s main
fi
EOF
}


# Les plugins sont extraits du dossier bundle (téléchargés s'ils y manquent)
# directement dans ~/.tmux/plugins : TPM les charge au démarrage de tmux, sans
# rien télécharger. Un plugin déjà présent n'est pas touché.
install_tmux_plugins() {
  local target_user="$1" home="$2" grp repo name
  grp="$(id -gn "$target_user")"
  install -d -o "$target_user" -g "$grp" -m 755 "$home/.tmux" "$home/.tmux/plugins"
  mkdir -p "$BUNDLE_DIR"

  for repo in $TMUX_PLUGINS; do
    name="${repo#*/}"
    if [ -d "$home/.tmux/plugins/$name" ]; then
      log "Plugin tmux $name déjà présent pour $target_user"
      continue
    fi
    # Sous-shell : un échec (pas d'internet, bundle incomplet) n'arrête pas le script
    if ! ( download_tmux_plugin "$repo" ); then
      warn "Plugin tmux $name indisponible : ignoré."
      continue
    fi
    log "Installation du plugin tmux $name pour $target_user"
    tar -xzf "$BUNDLE_DIR/tmux-plugin-${name}.tar.gz" -C "$home/.tmux/plugins"
  done

  chown -R "$target_user:$grp" "$home/.tmux"
}

step_shell() {
  require_existing_admin_user
  local idx col u home grp cfg
  local -a palette=(34 33 208 135 160 37)
  if [ -n "$HOST_COLOR" ]; then
    col="$HOST_COLOR"
  else
    idx=$(( $(hostname | cksum | cut -d' ' -f1) % ${#palette[@]} ))
    col="${palette[$idx]}"
  fi
  log "Configuration de tmux et du prompt Starship (couleur $col pour $(hostname))"
  apt-get update -y
  install_tmux
  install_starship
  write_clip_helper
  for u in "$ADMIN_USER" root; do
    home="$(get_home "$u")"
    grp="$(id -gn "$u")"
    # Préserver la configuration existante avant de la remplacer.
    if [ -f "$home/.tmux.conf" ] && ! grep -qF 'géré par bootstrap-node.sh' "$home/.tmux.conf"; then
      cp -a "$home/.tmux.conf" "$home/.tmux.conf.bak.$(date +%Y%m%d-%H%M%S)"
    fi
    write_tmux_conf "$home/.tmux.conf" "$col"
    install_tmux_plugins "$u" "$home"
    install -d -o "$u" -g "$grp" -m 755 "$home/.vim" "$home/.vim/undo"
    write_vim_conf "$home/.vimrc" "$col"
    chown "$u:$grp" "$home/.vimrc"
    find "$home" -maxdepth 1 -name '.vimrc.bak.*' -exec chown "$u:$grp" {} +
    install -d -o "$u" -g "$grp" -m 755 "$home/.config"
    chown "$u:$grp" "$home/.config"
    cfg="$home/.config/starship.toml"
    write_starship_config "$cfg" "$col"
    chown "$u:$grp" "$cfg"
    write_bash_shell "$home/.bash_shell" "$TMUX_AUTOSTART"
    touch "$home/.bashrc"
    sed -i '/# Prompt et alias du lab/d; /\.bash_lab/d; /# Shell du lab/d; /\.bash_shell/d' "$home/.bashrc"
    if grep -qF '# Outils de développement' "$home/.bashrc"; then
      sed -i '/# Outils de développement/i\
# Shell et prompt Starship du lab\
[ -f "$HOME/.bash_shell" ] \&\& . "$HOME/.bash_shell"' "$home/.bashrc"
    else
      printf '\n# Shell et prompt Starship du lab\n[ -f "$HOME/.bash_shell" ] && . "$HOME/.bash_shell"\n' >> "$home/.bashrc"
    fi
    if [ -f "$home/.bash_lab" ] && grep -qF 'géré par bootstrap-node.sh' "$home/.bash_lab"; then
      rm -f "$home/.bash_lab"
    fi
    chown "$u:$grp" "$home/.tmux.conf" "$home/.bash_shell" "$home/.bashrc"
  done
}

# -----------------------------------------------------------------------------
# docker — daemon Docker
# -----------------------------------------------------------------------------
# Note : k3s embarque son propre containerd et N'A PAS besoin de Docker. Docker
# sert ici à construire/tester des images en local. Les deux cohabitent.
step_docker() {
  if [ "$INSTALL_DOCKER" != "1" ]; then
    log "Docker ignoré (INSTALL_DOCKER=0)"
    return 0
  fi
  require_admin_user
  local arch codename dj="/etc/docker/daemon.json" tmp changed=0

  case "$DOCKER_SOURCE" in
    official)
      if dpkg -s docker.io >/dev/null 2>&1; then
        die "Le paquet Debian docker.io est installé : désinstalle-le ou utilise DOCKER_SOURCE=debian."
      fi
      arch="$(dpkg --print-architecture)"
      # shellcheck disable=SC1091
      codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
      log "Ajout du dépôt Docker ($codename, $arch)"
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Architectures: ${arch}
Signed-By: /etc/apt/keyrings/docker.asc
EOF
      apt-get update -y
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
      ;;
    debian)
      apt-get install -y docker.io
      ;;
    *) die "DOCKER_SOURCE doit valoir official ou debian." ;;
  esac

  # Configuration : rotation des logs (évite de remplir le disque), live-restore
  # (les conteneurs survivent à un redémarrage du daemon), dossier de données.
  mkdir -p /etc/docker
  tmp="$(mktemp)"
  {
    echo '{'
    echo '  "log-driver": "json-file",'
    echo '  "log-opts": { "max-size": "10m", "max-file": "3" },'
    if [ -n "$DOCKER_DATA_ROOT" ]; then
      echo '  "live-restore": true,'
      echo "  \"data-root\": \"$DOCKER_DATA_ROOT\""
    else
      echo '  "live-restore": true'
    fi
    echo '}'
  } > "$tmp"

  if [ -n "$DOCKER_DATA_ROOT" ]; then
    mkdir -p "$DOCKER_DATA_ROOT"
    case "$(findmnt -no FSTYPE -T "$DOCKER_DATA_ROOT" || true)" in
      ext4|xfs) ;;
      *) warn "$DOCKER_DATA_ROOT n'est pas en ext4/xfs : le driver overlay2 de Docker peut ne pas fonctionner." ;;
    esac
  fi

  if ! cmp -s "$tmp" "$dj" 2>/dev/null; then
    if [ -f "$dj" ]; then
      cp "$dj" "$dj.bak.$(date +%s)"
    fi
    install -m 644 "$tmp" "$dj"
    changed=1
  fi
  rm -f "$tmp"

  systemctl enable docker
  if [ "$changed" = "1" ]; then
    systemctl restart docker
  else
    systemctl start docker
  fi
  usermod -aG docker "$ADMIN_USER"
  warn "Le groupe docker donne un accès équivalent à root : $ADMIN_USER y est ajouté (reconnexion nécessaire)."
  docker info --format 'Docker {{.ServerVersion}} — driver {{.Driver}} — données {{.DockerRootDir}}' || true
}

# -----------------------------------------------------------------------------
# download — binaires hors dépôts Debian, rangés dans BUNDLE_DIR (amd64)
# -----------------------------------------------------------------------------
# Chaque fichier n'est téléchargé que s'il manque dans BUNDLE_DIR, puis vérifié
# avec la somme de contrôle publiée par son projet. Sur une machine sans
# internet, les étapes shell et kubectl trouvent tout dans ce dossier.
#   kubectl                 dl.k8s.io (somme .sha256)
#   kubecolor               GitHub kubecolor/kubecolor (checksums.txt)
#   starship                GitHub starship/starship, binaire statique musl
#                           (somme .sha256) : absent des dépôts Debian 12
#   tmux_*.deb              tmux 3.5a de bookworm-backports (le tmux 3.3a de
#   libjemalloc2_*.deb      Debian 12 est ancien) et sa dépendance ; sommes
#                           SHA256 de l'index de l'archive Debian
#   tmux-plugin-*.tar.gz    plugins tmux (TMUX_PLUGINS), clonés depuis GitHub en
#                           HTTPS avec leur dossier .git (mise à jour possible
#                           plus tard avec prefix + U) ; le commit est noté dans
#                           VERSIONS (pas de somme publiée par ces projets)
DEBIAN_MIRROR="https://deb.debian.org/debian"

# Dernière version publiée d'un projet GitHub (ex: v1.26.0)
gh_latest() {
  curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$1/releases/latest" \
    | sed 's#.*/tag/##'
}

# Vérifie la somme SHA256 d'un fichier, l'efface si elle est fausse
check_sha256() {
  local file="$1" expected="$2"
  if ! echo "${expected}  ${file}" | sha256sum -c --quiet - >/dev/null 2>&1; then
    rm -f "$file"
    die "Somme de contrôle invalide pour $(basename "$file") : fichier supprimé."
  fi
}

bundle_note() {
  echo "$1" >> "$BUNDLE_DIR/VERSIONS"
}

download_kubectl() {
  local ver tmp
  [ -x "$BUNDLE_DIR/kubectl" ] && return 0
  ver="$KUBECTL_VERSION"
  if [ -z "$ver" ]; then
    ver="$(curl -fsSL https://dl.k8s.io/release/stable.txt)" \
      || die "kubectl absent de $BUNDLE_DIR et téléchargement impossible (pas d'internet ?). Lance « download » sur une machine connectée."
  fi
  ver="v${ver#v}"
  log "Téléchargement de kubectl $ver"
  tmp="$BUNDLE_DIR/kubectl.part"
  curl -fsSL -o "$tmp" "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl"
  check_sha256 "$tmp" "$(curl -fsSL "https://dl.k8s.io/release/${ver}/bin/linux/amd64/kubectl.sha256")"
  chmod 755 "$tmp"
  mv "$tmp" "$BUNDLE_DIR/kubectl"
  bundle_note "kubectl $ver"
}

download_kubecolor() {
  local ver tgz tmp sum
  [ -x "$BUNDLE_DIR/kubecolor" ] && return 0
  ver="${KUBECOLOR_VERSION:-$(gh_latest kubecolor/kubecolor || true)}"
  [ -n "$ver" ] \
    || die "kubecolor absent de $BUNDLE_DIR et téléchargement impossible (pas d'internet ?). Lance « download » sur une machine connectée."
  ver="v${ver#v}"
  log "Téléchargement de kubecolor $ver"
  tgz="kubecolor_${ver#v}_linux_amd64.tar.gz"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/$tgz" "https://github.com/kubecolor/kubecolor/releases/download/${ver}/${tgz}"
  sum="$(curl -fsSL "https://github.com/kubecolor/kubecolor/releases/download/${ver}/checksums.txt" \
    | awk -v f="$tgz" '$2 == f { print $1 }')"
  [ -n "$sum" ] || { rm -rf "$tmp"; die "Somme de contrôle de $tgz introuvable."; }
  check_sha256 "$tmp/$tgz" "$sum"
  tar -xzf "$tmp/$tgz" -C "$tmp" kubecolor
  install -m 755 "$tmp/kubecolor" "$BUNDLE_DIR/kubecolor"
  rm -rf "$tmp"
  bundle_note "kubecolor $ver"
}

download_starship() {
  local ver tgz tmp
  [ -x "$BUNDLE_DIR/starship" ] && return 0
  ver="${STARSHIP_VERSION:-$(gh_latest starship/starship || true)}"
  [ -n "$ver" ] \
    || die "starship absent de $BUNDLE_DIR et téléchargement impossible (pas d'internet ?). Lance « download » sur une machine connectée."
  ver="v${ver#v}"
  log "Téléchargement de Starship $ver"
  tgz="starship-x86_64-unknown-linux-musl.tar.gz"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/$tgz" "https://github.com/starship/starship/releases/download/${ver}/${tgz}"
  check_sha256 "$tmp/$tgz" \
    "$(curl -fsSL "https://github.com/starship/starship/releases/download/${ver}/${tgz}.sha256" | awk '{ print $1 }')"
  tar -xzf "$tmp/$tgz" -C "$tmp" starship
  install -m 755 "$tmp/starship" "$BUNDLE_DIR/starship"
  rm -rf "$tmp"
  bundle_note "starship $ver"
}

# Télécharge un paquet .deb de l'archive Debian : suite, paquet
download_debian_deb() {
  local suite="$1" pkg="$2" info file sum
  if ls "$BUNDLE_DIR/${pkg}"_*_amd64.deb >/dev/null 2>&1; then
    return 0
  fi
  log "Téléchargement de $pkg ($suite)"
  info="$(curl -fsSL "$DEBIAN_MIRROR/dists/${suite}/main/binary-amd64/Packages.xz" | xz -dc \
    | awk -v p="$pkg" '$0 == "Package: " p { f = 1 } f && /^Filename:/ { n = $2 } f && /^SHA256:/ { h = $2 } f && /^$/ { print n, h; exit }' || true)"
  file="${info% *}"
  sum="${info#* }"
  [ -n "$info" ] && [ -n "$file" ] && [ -n "$sum" ] \
    || die "$pkg absent de $BUNDLE_DIR et introuvable dans $suite (pas d'internet ?). Lance « download » sur une machine connectée."
  curl -fsSL -o "$BUNDLE_DIR/$(basename "$file")" "$DEBIAN_MIRROR/$file"
  check_sha256 "$BUNDLE_DIR/$(basename "$file")" "$sum"
  bundle_note "$(basename "$file")"
}

download_tmux_deb() {
  download_debian_deb bookworm-backports tmux
  download_debian_deb bookworm libjemalloc2
}

# Archive un plugin tmux depuis GitHub : dépôt « auteur/nom »
download_tmux_plugin() {
  local repo="$1" name="${1#*/}" tgz tmp commit
  tgz="$BUNDLE_DIR/tmux-plugin-${name}.tar.gz"
  [ -s "$tgz" ] && return 0
  log "Téléchargement du plugin tmux $repo"
  tmp="$(mktemp -d)"
  if ! git clone -q --depth 1 "https://github.com/${repo}" "$tmp/$name"; then
    rm -rf "$tmp"
    die "Plugin tmux $repo absent de $BUNDLE_DIR et téléchargement impossible (pas d'internet ?). Lance « download » sur une machine connectée."
  fi
  commit="$(git -C "$tmp/$name" rev-parse --short HEAD)"
  tar -czf "$tgz.part" -C "$tmp" "$name"
  mv "$tgz.part" "$tgz"
  rm -rf "$tmp"
  bundle_note "tmux-plugin $repo $commit"
}

require_amd64() {
  [ "$(dpkg --print-architecture 2>/dev/null || uname -m)" = "amd64" ] \
    || die "Binaires prévus pour amd64 uniquement ; architecture : $(dpkg --print-architecture 2>/dev/null || uname -m)."
}

step_download() {
  local repo
  require_amd64
  mkdir -p "$BUNDLE_DIR"
  download_kubectl
  download_kubecolor
  download_starship
  download_tmux_deb
  for repo in $TMUX_PLUGINS; do
    download_tmux_plugin "$repo"
  done
  log "Binaires prêts dans $BUNDLE_DIR :"
  ls -lh "$BUNDLE_DIR"
}

# tmux : paquet natif sur Debian 13, tmux 3.5a des backports sur Debian 12
install_tmux() {
  local major
  major="$(debian_major)"
  if [ "$major" = "12" ]; then
    require_amd64
    mkdir -p "$BUNDLE_DIR"
    download_tmux_deb
    log "Installation de tmux 3.5a (bookworm-backports)"
    apt-get install -y "$BUNDLE_DIR"/libjemalloc2_*_amd64.deb "$BUNDLE_DIR"/tmux_*_amd64.deb
  else
    apt-get install -y tmux
  fi
}

# Starship : paquet natif sur Debian 13, binaire officiel sur Debian 12
install_starship() {
  local major
  major="$(debian_major)"
  if [ "$major" = "12" ]; then
    require_amd64
    mkdir -p "$BUNDLE_DIR"
    download_starship
    log "Installation de Starship dans /usr/local/bin"
    install -m 755 "$BUNDLE_DIR/starship" /usr/local/bin/starship
  else
    apt-get install -y starship
  fi
}

# -----------------------------------------------------------------------------
# kubectl — kubectl, kubecolor, kubeconfig, alias k/kns et complétion
# -----------------------------------------------------------------------------
# Sur un nœud k3s, /usr/local/bin/kubectl est un lien vers k3s : il est gardé.
# Ailleurs, le kubectl officiel est installé depuis BUNDLE_DIR. kubens (paquet
# Debian kubectx, natif sur Debian 12 et 13) change de namespace : alias kns.
install_kubectl_bin() {
  if [ "$(readlink /usr/local/bin/kubectl 2>/dev/null)" = "k3s" ]; then
    log "k3s est installé ici : son kubectl intégré est utilisé."
    return 0
  fi
  require_amd64
  mkdir -p "$BUNDLE_DIR"
  download_kubectl
  log "Installation de kubectl dans /usr/local/bin"
  install -m 755 "$BUNDLE_DIR/kubectl" /usr/local/bin/kubectl
}

install_kubecolor_bin() {
  require_amd64
  mkdir -p "$BUNDLE_DIR"
  download_kubecolor
  log "Installation de kubecolor dans /usr/local/bin"
  install -m 755 "$BUNDLE_DIR/kubecolor" /usr/local/bin/kubecolor
}

# Installe ~/.kube/config pour DEV_USER :
#   KUBECONFIG_SOURCE défini : copié par SSH depuis ce serveur, l'adresse
#     127.0.0.1 remplacée par celle du serveur ;
#   sinon, sur un nœud k3s : copie locale de /etc/rancher/k3s/k3s.yaml
#     (127.0.0.1 : chaque serveur parle à sa propre API, ce qui permet de
#     piloter le cluster depuis B ou C si A est tombé).
# Le contexte « default » de k3s est renommé KUBE_CONTEXT, puis fusionné avec
# un kubeconfig existant (sauvegardé) ; il devient le contexte courant.
setup_user_kubeconfig() {
  local home grp kdir cfg new merged api="" host
  home="$(get_home "$DEV_USER")"
  grp="$(id -gn "$DEV_USER")"
  kdir="$home/.kube"
  cfg="$kdir/config"
  new="$(mktemp)"
  merged="$(mktemp)"

  if [ -n "$KUBECONFIG_SOURCE" ]; then
    log "Copie du kubeconfig depuis $KUBECONFIG_SOURCE (SSH en tant que $DEV_USER)"
    # SSH lancé en tant que DEV_USER : sa clé et son ~/.ssh/config sont utilisés.
    if ! runuser -u "$DEV_USER" -- env HOME="$home" \
         ssh "$KUBECONFIG_SOURCE" 'cat ~/.kube/config' > "$new" \
       || ! grep -q '^apiVersion:' "$new"; then
      rm -f "$new" "$merged"
      die "Kubeconfig introuvable sur $KUBECONFIG_SOURCE (~/.kube/config). Lance d'abord « sudo ./bootstrap-node.sh kubectl » sur ce serveur."
    fi
    # Adresse de l'API : K3S_API, sinon l'adresse réelle derrière l'alias SSH
    api="$K3S_API"
    if [ -z "$api" ]; then
      host="${KUBECONFIG_SOURCE#*@}"
      api="$(runuser -u "$DEV_USER" -- env HOME="$home" ssh -G "$host" 2>/dev/null \
        | awk '$1 == "hostname" { print $2; exit }' || true)"
      api="${api:-$host}"
    fi
    sed -i -E "s#(server: https://)(127\.0\.0\.1|localhost)(:[0-9]+)#\1${api}\3#" "$new"
  elif [ -r "$K3S_KUBECONFIG" ]; then
    log "Kubeconfig local de k3s copié pour $DEV_USER"
    cp "$K3S_KUBECONFIG" "$new"
    if [ -n "$K3S_API" ]; then
      sed -i -E "s#(server: https://)(127\.0\.0\.1|localhost)(:[0-9]+)#\1${K3S_API}\3#" "$new"
    fi
  else
    rm -f "$new" "$merged"
    warn "Pas de k3s ici et KUBECONFIG_SOURCE vide : aucun kubeconfig installé (ex: KUBECONFIG_SOURCE=nas1)."
    return 0
  fi
  sed -i -E "s/^([[:space:]-]*)(name|cluster|user|current-context): default$/\1\2: ${KUBE_CONTEXT}/" "$new"

  install -d -m 700 -o "$DEV_USER" -g "$grp" "$kdir"
  if [ -s "$cfg" ]; then
    cp -a "$cfg" "$cfg.bak.$(date +%Y%m%d-%H%M%S)"
    KUBECONFIG="$new:$cfg" kubectl config view --flatten > "$merged"
    install -m 600 -o "$DEV_USER" -g "$grp" "$merged" "$cfg"
  else
    install -m 600 -o "$DEV_USER" -g "$grp" "$new" "$cfg"
  fi
  rm -f "$new" "$merged"
  log "Contexte « $KUBE_CONTEXT » écrit dans $cfg"

  if runuser -u "$DEV_USER" -- env HOME="$home" KUBECONFIG="$cfg" \
       kubectl --context "$KUBE_CONTEXT" --request-timeout=10s get nodes; then
    log "Le cluster répond."
  else
    warn "Le cluster ne répond pas. Vérifie que l'API (port 6443) est joignable et figure dans le certificat (K3S_TLS_SAN)."
  fi
}

# Écrit ~/.bash_kubectl : alias k et kns, complétion (chargé depuis ~/.bashrc).
# Le contexte courant s'affiche dans le prompt Starship (module kubernetes).
#
# POURQUOI LA COMPLÉTION DISPARAÎT AVEC UN ALIAS : bash attache la complétion au
# NOM de la commande. kubectl a la sienne (fonction __start_kubectl), mais pas
# « kubecolor » ni l'alias « k ». On leur rattache donc explicitement la même
# fonction avec « complete -o default -F __start_kubectl ... ».
write_kubectl_shell() {
  local file="$1"
  {
    echo "# ~/.bash_kubectl — kubectl : couleur, alias k et kns, complétion (géré par bootstrap-node.sh)"
    echo "LAB_K3S_KUBECONFIG=${K3S_KUBECONFIG}"
  } > "$file"
  cat >> "$file" <<'EOF'

[[ $- == *i* ]] || return 0

# Retire d'éventuels alias k/kubectl : un alias empêche de définir une fonction du même nom
unalias k kubectl 2>/dev/null || true

if command -v kubectl >/dev/null 2>&1; then
  # Sans ~/.kube/config (root sur un nœud), on lit le kubeconfig de k3s
  if [ -z "${KUBECONFIG:-}" ] && [ ! -r "$HOME/.kube/config" ] && [ -r "$LAB_K3S_KUBECONFIG" ]; then
    export KUBECONFIG="$LAB_K3S_KUBECONFIG"
  fi
  # Charge bash-completion si ce shell ne l'a pas fait (le .bashrc de root, par ex.)
  if ! type _init_completion >/dev/null 2>&1 && [ -f /usr/share/bash-completion/bash_completion ]; then
    . /usr/share/bash-completion/bash_completion
  fi
  # Fonction __start_kubectl (déjà fournie par /etc/bash_completion.d/kubectl si présent)
  if ! type __start_kubectl >/dev/null 2>&1; then
    source <(kubectl completion bash 2>/dev/null)
  fi

  if command -v kubecolor >/dev/null 2>&1; then
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

# kns = kubens : sans argument, liste les namespaces (le courant en surbrillance) ;
# « kns monappli » en fait le namespace par défaut ; « kns - » revient au
# précédent. bash-completion ne charge la complétion qu'à la demande, d'après le
# nom de la commande : « kns » n'a pas de fichier, on charge donc celui de
# kubens puis on le rattache à l'alias.
if command -v kubens >/dev/null 2>&1; then
  alias kns=kubens
  if ! type _kube_namespaces >/dev/null 2>&1 && [ -f /usr/share/bash-completion/completions/kubens.bash ]; then
    . /usr/share/bash-completion/completions/kubens.bash
  fi
  if type _kube_namespaces >/dev/null 2>&1; then
    complete -F _kube_namespaces kns
  fi
fi
EOF
}

step_kubectl() {
  require_dev_user
  log "Shell kubectl configuré pour $DEV_USER et pour root"
  local tmp u home grp
  install_kubectl_bin
  install_kubecolor_bin
  apt-get install -y kubectx bash-completion

  setup_user_kubeconfig

  # Complétion système (fichier statique : démarrage de shell plus rapide)
  tmp="$(mktemp)"
  if kubectl completion bash > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    mkdir -p /etc/bash_completion.d
    install -m 644 "$tmp" /etc/bash_completion.d/kubectl
  fi
  rm -f "$tmp"

  # kube-ps1 d'une ancienne version de ces scripts : remplacé par Starship
  rm -rf /usr/local/share/kube-ps1

  for u in "$DEV_USER" root; do
    home="$(get_home "$u")"
    grp="$(id -gn "$u")"
    write_kubectl_shell "$home/.bash_kubectl"
    touch "$home/.bashrc"
    sed -i 's/^# kubectl : couleur, alias k\/kns, complétion, prompt$/# kubectl : couleur, alias k et kns, complétion/' "$home/.bashrc"
    if ! grep -qF '.bash_kubectl' "$home/.bashrc"; then
      printf '\n# kubectl : couleur, alias k et kns, complétion\n[ -f "$HOME/.bash_kubectl" ] && . "$HOME/.bash_kubectl"\n' >> "$home/.bashrc"
    fi
    chown "$u:$grp" "$home/.bash_kubectl" "$home/.bashrc"
  done
  log "kubectl : alias k et kns, complétion configurés (ouvre un nouveau shell ou : source ~/.bashrc)"
}

summary() {
  cat <<EOF

=============================================================================
Nœud $(hostname) prêt.

Étapes suivantes :
  1. Reconnecte-toi en tant que ${ADMIN_USER:-ton utilisateur} (groupes sudo/docker pris en compte).
  2. Lance la préparation sur les autres machines.
  3. Installe k3s UN nœud à la fois avec install-k3s-lab.sh (voir son en-tête).
  4. Puis, sur chaque nœud : sudo ADMIN_USER=${ADMIN_USER:-admin} ./bootstrap-node.sh kubectl
=============================================================================
EOF
}

main() {
  local cmd="${1:-all}"
  case "$cmd" in
    -h|--help|help)
      awk '/^# bootstrap-node.sh/ { show=1 } show { print; if ($0 == "# =============================================================================" && ++separators == 2) exit }' "$0" | sed 's/^# \{0,1\}//'
      return 0
      ;;
    download)
      # Pas besoin de root : on écrit seulement dans BUNDLE_DIR
      step_download
      return 0
      ;;
  esac
  need_root
  case "$cmd" in
    all)
      check_os
      step_packages
      base
      step_user
      step_ssh
      step_shell
      step_docker
      summary
      ;;
    packages)  step_packages ;;
    base)      base ;;
    dev)       dev ;;
    user)      step_user ;;
    ssh)       step_ssh ;;
    shell)     step_shell ;;
    docker)    step_docker ;;
    kubectl)   step_kubectl ;;
    *)
      die "Étape inconnue : $cmd (all | packages | base | dev | user | ssh | shell | docker | kubectl | download)."
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi