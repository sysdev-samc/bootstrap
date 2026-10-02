#!/usr/bin/env bash
# =============================================================================
# bootstrap-node.sh — Préparer un nœud Debian 13 (amd64 ou arm64) pour le lab
# =============================================================================
#
# À lancer sur CHAQUE machine (nas1, nas2, nas3), en root. Le script est
# IDEMPOTENT : tu peux le relancer sans casser ce qui est déjà en place.
#
# CE QU'IL FAIT
#   packages   Paquets de base (sudo, tmux, git, chrony...) + prérequis Longhorn
#              (open-iscsi, nfs-common). chrony synchronise l'heure : indispensable
#              pour etcd et les certificats Kubernetes.
#   base       Reprend de façon compatible Debian 13 les réglages utiles du rôle
#              Ansible base : outils d'exploitation, bash, Git, pager, cron et
#              permissions système. Aucun mot de passe root n'est défini.
#   dev        Installe les outils de développement interactifs (fzf, zoxide,
#              direnv, bat, fd) pour l'utilisateur d'administration.
#   user       Crée l'utilisateur d'administration, membre du groupe sudo, et
#              installe ta clé publique SSH.
#   ssh        Durcit sshd (root interdit, mot de passe interdit SI une clé est
#              installée) et affiche le bloc à copier dans ton ~/.ssh/config.
#   shell      Configure tmux et le prompt Starship (couleur propre à chaque
#              machine, Git et Kubernetes) pour l'utilisateur et root.
#   docker     Installe le daemon Docker (dépôt officiel, amd64 ou arm64 détecté
#              automatiquement) avec rotation des logs.
#   k3s-prep   Prépare le système pour k3s : modules noyau, sysctl, swap, cgroups,
#              pare-feu, fichier hosts.
#   k3s        (à la demande) Lance install-k3s-lab.sh avec le bon rôle.
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
#   Installer k3s ensuite, UN nœud à la fois, dans l'ordre :
#     sudo K3S_ROLE=init  K3S_TLS_SAN=k3s.lab.local ./bootstrap-node.sh k3s    # nas1
#     sudo K3S_ROLE=join  K3S_URL=https://IP_NAS1:6443 K3S_TOKEN=... ./bootstrap-node.sh k3s   # nas2
#     sudo K3S_ROLE=etcd  K3S_URL=https://IP_NAS1:6443 K3S_TOKEN=... ./bootstrap-node.sh k3s   # nas3 (ARM)
#
# VARIABLES
#   ADMIN_USER        (obligatoire) utilisateur à créer/configurer, ex: admin
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
#   DISABLE_SWAP      1 (défaut) = désactiver le swap (recommandé pour Kubernetes)
#   CLUSTER_CIDR      réseau du lab (ex: 192.168.1.0/24) : ouvre les ports k3s si
#                     ufw est actif
#   HOSTS_ENTRIES     noms des nœuds, ex: nas1=192.168.1.10,nas2=192.168.1.11,nas3=192.168.1.12
#   K3S_ROLE          init | join | etcd | agent (étape « k3s »)
#   ALLOW_32BIT       1 = autoriser un OS ARM 32 bits pour k3s (déconseillé)
#   BASE_GIT_CREDENTIAL_CACHE_TIMEOUT  durée en secondes du cache Git (défaut 900,
#                     0 = ne pas configurer le cache).
#   DEV_USER          utilisateur à configurer à l'étape dev (défaut : ADMIN_USER,
#                     ou l'utilisateur ayant lancé sudo).
# =============================================================================

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

ADMIN_USER="${ADMIN_USER:-}"
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
DISABLE_SWAP="${DISABLE_SWAP:-1}"
CLUSTER_CIDR="${CLUSTER_CIDR:-}"
HOSTS_ENTRIES="${HOSTS_ENTRIES:-}"
K3S_ROLE="${K3S_ROLE:-}"
ALLOW_32BIT="${ALLOW_32BIT:-0}"
BASE_GIT_CREDENTIAL_CACHE_TIMEOUT="${BASE_GIT_CREDENTIAL_CACHE_TIMEOUT:-900}"
DEV_USER="${DEV_USER:-${ADMIN_USER:-${SUDO_USER:-}}}"

log() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mATTENTION: %s\033[0m\n' "$*" >&2; }
die() { printf '\033[1;31mERREUR: %s\033[0m\n' "$*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "Lance ce script en root (sudo)."
}

get_home() {
  getent passwd "$1" | cut -d: -f6
}

require_admin_user() {
  [ -n "$ADMIN_USER" ] || die "ADMIN_USER manquant (ex: sudo ADMIN_USER=admin $0)."
  [ "$ADMIN_USER" != "root" ] || die "ADMIN_USER doit être un utilisateur normal, pas root."
}

require_dev_user() {
  [ -n "$DEV_USER" ] || die "DEV_USER ou ADMIN_USER manquant pour l'étape dev."
  [ "$DEV_USER" != "root" ] || die "DEV_USER doit être un utilisateur normal."
  id "$DEV_USER" >/dev/null 2>&1 || die "Utilisateur DEV_USER introuvable : $DEV_USER"
}

check_os() {
  local arch
  arch="$(dpkg --print-architecture)"
  # shellcheck disable=SC1091
  . /etc/os-release
  log "Système : ${PRETTY_NAME:-inconnu} — architecture : $arch — hôte : $(hostname)"
  if [ "${ID:-}" != "debian" ]; then
    warn "Ce script vise Debian ; système détecté : ${ID:-?}."
  elif [ "${VERSION_ID:-}" != "13" ]; then
    warn "Ce script est prévu pour Debian 13 ; version détectée : ${VERSION_ID:-?}."
  fi
}

# -----------------------------------------------------------------------------
# packages — base du système
# -----------------------------------------------------------------------------
step_packages() {
  log "Installation des paquets de base"
  apt-get update -y
  apt-get install -y sudo openssh-server curl ca-certificates gnupg tmux git vim-nox \
    htop jq rsync chrony bash-completion open-iscsi nfs-common cryptsetup dmsetup \
    thefuck command-not-found curl ca-certificates most apt-file 
  systemctl enable --now chrony
  systemctl enable --now iscsid
}

base() {
  local pkg tmp bashrc marker_begin marker_end key value editor_bin candidate
  local -a requested available

  systemctl enable --now cron

  [ -f ~/.vimrc ] && cp ~/.vimrc ~/.vimrc.bak.$(date +%F)
  mkdir -p ~/.vim/undo

  cat >> ~/.vimrc <<'EOF'

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

" Revenir à la dernière position à la réouverture d'un fichier
autocmd BufReadPost * if line("'\"") > 1 && line("'\"") <= line("$") | exe "normal! g`\"" | endif

" Supprimer les espaces de fin de ligne avec F4
nnoremap <F4> :%s/\s\+$//e<CR>:nohlsearch<CR>
EOF

  # Équivalent moderne de la configuration Git du rôle, sans imposer une
  # identité : celle-ci doit rester propre à chaque utilisateur/projet.
  git config --system core.whitespace 'trailing-space,space-before-tab,indent-with-non-tab'
  git config --system color.ui true
  git config --system tag.sort version:refname
  git config --system alias.a add
  git config --system alias.b 'branch -vv --all'
  git config --system alias.c commit
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
set -g default-terminal "screen-256color"
set -ga terminal-overrides ",*256col*:Tc"
set -g history-limit 50000
set -g mouse on
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -sg escape-time 10
set -g focus-events on
setw -g mode-keys vi

# Recharger la config : prefix + r
bind r source-file ~/.tmux.conf \\; display "tmux.conf rechargé"

# Découpages plus intuitifs, dans le dossier courant
bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"
bind c new-window -c "#{pane_current_path}"

# Changer de panneau avec Alt + flèches
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# Barre d'état : le nom de la machine a sa couleur, pour ne pas se tromper de nœud
set -g status-interval 5
set -g status-style "bg=colour235,fg=colour250"
set -g status-left-length 30
set -g status-left "#[bg=colour${col},fg=colour16,bold] #H #[default] "
set -g status-right "#[fg=colour245]load #(cut -d' ' -f1-3 /proc/loadavg)  #[fg=colour250]%d/%m %H:%M "
setw -g window-status-format " #I:#W "
setw -g window-status-current-format " #I:#W "
setw -g window-status-current-style "bg=colour${col},fg=colour16,bold"
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

step_shell() {
  require_admin_user
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
  apt-get install -y starship
  for u in "$ADMIN_USER" root; do
    home="$(get_home "$u")"
    grp="$(id -gn "$u")"
    write_tmux_conf "$home/.tmux.conf" "$col"
    install -d -o "$u" -g "$grp" -m 755 "$home/.config"
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
# k3s-prep — préparation du système pour k3s
# -----------------------------------------------------------------------------
step_k3s_prep() {
  local arch u c p name ip
  arch="$(dpkg --print-architecture)"
  log "Préparation du système pour k3s (architecture $arch)"

  case "$arch" in
    amd64|arm64) ;;
    armhf|armel)
      warn "OS ARM 32 bits ($arch) : etcd n'y est pas officiellement supporté. Utilise un Debian arm64 pour un serveur k3s."
      ;;
  esac

  # Modules noyau requis par le réseau des conteneurs
  printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k3s.conf
  modprobe overlay || warn "Module overlay indisponible"
  modprobe br_netfilter || warn "Module br_netfilter indisponible"

  # Paramètres noyau : routage entre pods, filtrage des ponts, limites inotify
  # (les valeurs par défaut sont trop basses pour de nombreux pods).
  cat > /etc/sysctl.d/90-k3s.conf <<'EOF'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
fs.inotify.max_user_instances = 512
fs.inotify.max_user_watches = 524288
EOF
  sysctl --system >/dev/null

  # Swap : Kubernetes attend qu'il soit désactivé. Attention sur une machine à
  # 2 Go de RAM : sans swap, un dépassement mémoire déclenche l'OOM killer.
  if [ "$DISABLE_SWAP" = "1" ]; then
    swapoff -a || true
    sed -i -E 's|^([^#].*[[:space:]]swap[[:space:]].*)$|# \1  # désactivé par bootstrap-node.sh|' /etc/fstab
    for u in dphys-swapfile.service zramswap.service armbian-zram-config.service; do
      if systemctl list-unit-files "$u" 2>/dev/null | grep -q "^$u"; then
        systemctl disable --now "$u" 2>/dev/null || true
      fi
    done
  fi

  # cgroups v2 avec les contrôleurs nécessaires (important sur les cartes ARM)
  if [ -r /sys/fs/cgroup/cgroup.controllers ]; then
    for c in cpu memory pids; do
      if ! grep -qw "$c" /sys/fs/cgroup/cgroup.controllers; then
        warn "Contrôleur cgroup '$c' absent. Ajoute 'cgroup_enable=memory cgroup_memory=1' aux paramètres de démarrage du noyau (fichier dépendant de ta carte), puis redémarre."
      fi
    done
  else
    warn "cgroups v2 non détectés (/sys/fs/cgroup/cgroup.controllers absent) : k3s peut mal fonctionner."
  fi

  # multipathd vole les disques virtuels de Longhorn : on l'en écarte
  if command -v multipathd >/dev/null 2>&1; then
    if ! grep -q 'devnode "^sd\[a-z0-9\]+"' /etc/multipath.conf 2>/dev/null; then
      cat >> /etc/multipath.conf <<'EOF'
blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
      systemctl restart multipathd || true
    fi
  fi

  # Noms des nœuds dans /etc/hosts (bloc géré, le reste du fichier n'est pas touché)
  if [ -n "$HOSTS_ENTRIES" ]; then
    sed -i '/# BEGIN lab-nodes/,/# END lab-nodes/d' /etc/hosts
    {
      echo "# BEGIN lab-nodes"
      IFS=',' read -ra pairs <<< "$HOSTS_ENTRIES"
      for p in "${pairs[@]}"; do
        name="${p%%=*}"
        ip="${p#*=}"
        echo "$ip $name"
      done
      echo "# END lab-nodes"
    } >> /etc/hosts
    log "Noms des nœuds ajoutés à /etc/hosts"
  fi

  # Pare-feu : seulement si ufw est actif (Debian n'en installe pas par défaut)
  if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    if [ -n "$CLUSTER_CIDR" ]; then
      log "Ouverture des ports k3s dans ufw pour $CLUSTER_CIDR"
      ufw allow from "$CLUSTER_CIDR" to any port 6443 proto tcp
      ufw allow from "$CLUSTER_CIDR" to any port 2379:2380 proto tcp
      ufw allow from "$CLUSTER_CIDR" to any port 10250 proto tcp
      ufw allow from "$CLUSTER_CIDR" to any port 8472 proto udp
      ufw allow from 10.42.0.0/16 to any
      ufw allow from 10.43.0.0/16 to any
    else
      warn "ufw est actif : définis CLUSTER_CIDR (ex: 192.168.1.0/24) pour ouvrir 6443, 2379-2380, 10250 (tcp) et 8472 (udp)."
    fi
  fi
}

# -----------------------------------------------------------------------------
# k3s — installation, déléguée à install-k3s-lab.sh (même dossier)
# -----------------------------------------------------------------------------
step_k3s() {
  [ -n "$K3S_ROLE" ] || die "K3S_ROLE manquant : init | join | etcd | agent."
  local script arch
  script="$(dirname "$(readlink -f "$0")")/install-k3s-lab.sh"
  [ -f "$script" ] || die "install-k3s-lab.sh introuvable à côté de ce script ($script)."
  arch="$(dpkg --print-architecture)"
  if { [ "$arch" = "armhf" ] || [ "$arch" = "armel" ]; } && [ "$ALLOW_32BIT" != "1" ]; then
    die "OS ARM 32 bits ($arch) : etcd n'est pas officiellement supporté. Installe un Debian arm64 (ou ALLOW_32BIT=1 à tes risques)."
  fi
  log "Installation de k3s, rôle : $K3S_ROLE"
  case "$K3S_ROLE" in
    init)  bash "$script" server ;;
    join)  bash "$script" server-join ;;
    etcd)  ETCD_ONLY=1 bash "$script" server-join ;;
    agent) bash "$script" agent ;;
    *) die "K3S_ROLE inconnu : $K3S_ROLE (init | join | etcd | agent)." ;;
  esac
}

summary() {
  cat <<EOF

=============================================================================
Nœud $(hostname) prêt.

Étapes suivantes :
  1. Reconnecte-toi en tant que ${ADMIN_USER:-ton utilisateur} (groupes sudo/docker pris en compte).
  2. Lance la préparation sur les autres machines.
  3. Installe k3s UN nœud à la fois, dans l'ordre (voir l'en-tête du script) :
       nas1 -> K3S_ROLE=init    nas2 -> K3S_ROLE=join    nas3 (ARM) -> K3S_ROLE=etcd
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
      step_k3s_prep
      summary
      ;;
    packages)  step_packages ;;
    base)      base ;;
    dev)       dev ;;
    user)      step_user ;;
    ssh)       step_ssh ;;
    shell)     step_shell ;;
    docker)    step_docker ;;
    k3s-prep)  step_k3s_prep ;;
    k3s)       step_k3s ;;
    *)
      die "Étape inconnue : $cmd (all | packages | base | dev | user | ssh | shell | docker | k3s-prep | k3s)."
      ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
