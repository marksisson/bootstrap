#!/usr/bin/env bash
set -euo pipefail

# prompt for sudo upfront
if ! sudo -n true 2>/dev/null; then
  echo "Requesting sudo access..."
  sudo -v < /dev/tty || { echo "Failed to get sudo access. Exiting."; exit 1; }
fi

# Keep sudo alive in background (refresh every 60s)
(while true; do sudo -n true; sleep 60; done) & SUDO_KEEPALIVE_PID=$!

# Make sure to kill the background process on exit
trap 'kill $SUDO_KEEPALIVE_PID' EXIT

# install nix
if ! command -v nix &>/dev/null; then
  echo "Installing Nix..."
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm
fi

# make nix available to current script
if [[ ! -n "${NIX_PROFILES:-}" ]]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# use canonical nixpkgs
if [[ ! -n "${NIXPKGS:-}" ]]; then
  NIXPKGS=$(nix eval --raw --impure --expr 'let flake = builtins.getFlake "github:marksisson/parts"; in flake.inputs.nixpkgs.outPath')
fi

# install packages needed by remainder of script
if [ -z "${SCRIPT_IN_NIX_SHELL:-}" ]; then
  export SCRIPT_IN_NIX_SHELL=1
  exec nix shell nixpkgs#git nixpkgs#gnupg --command "$0" "$@"
fi

# install gnupg configuration
export GNUPGHOME="$HOME/.config/gnupg"
if [ ! -f "$GNUPGHOME/gpg-agent.conf" ]; then
  nix run github:marksisson/gnupg
fi

# enable ssh via gpg-agent
gpgconf --launch gpg-agent
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)

# prompt for host (with defaults)
default_host="$(hostname -s 2>/dev/null || hostname)"
read -rp "Host name [$default_host]: " HOST < /dev/tty
HOST="${HOST:-$default_host}"

# prompt for user (with defaults)
default_user="$(whoami)"
read -rp "User name [$default_user]: " USER < /dev/tty
USER="${USER:-$default_user}"

# detect OS
is_darwin=false
is_linux=false
case "$(uname -s)" in
    Darwin*) is_darwin=true ;;
    Linux*)  is_linux=true ;;
esac

if $is_darwin; then
  # move files that nix-darwin will overwrite
  if [ -f /etc/nix/nix.custom.conf ]; then
    sudo mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
  fi
  if [ -f /etc/zshenv ]; then
    sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin
  fi

  # install nix-darwin configuration
  if ! command -v darwin-rebuild &>/dev/null; then
    sudo nix run --override-input nixpkgs path:${NIXPKGS} github:nix-darwin/nix-darwin#darwin-rebuild -- \
      switch --flake git+ssh://git@github.com/marksisson/configurations#${HOST}
  fi

  # restart nix daemon to pickup nix configuration changes
  sudo launchctl kickstart -k system/systems.determinate.nix-daemon
fi

# install home-manager configuration
if ! command -v home-manager &>/dev/null; then
  export NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1
  nix run --override-input nixpkgs path:${NIXPKGS} github:nix-community/home-manager#home-manager -- \
    switch -b backup --flake git+ssh://git@github.com/marksisson/configurations#${USER}@${HOST} --impure
fi

echo "Done!"
