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

# use local nixpkgs
if [[ ! -n "${NIXPKGS:-}" ]]; then
  NIXPKGS=$(nix eval --raw --impure --expr 'let flake = builtins.getFlake "github:marksisson/parts"; in flake.inputs.nixpkgs.outPath')
fi

nix registry add nixpkgs $NIXPKGS

# install packages needed by remainder of script
if [ -z "${SCRIPT_IN_NIX_SHELL:-}" ]; then
  export SCRIPT_IN_NIX_SHELL=1
  exec nix shell nixpkgs#git nixpkgs#gnupg --command "$0" "$@"
fi

# install gnupg configuration
if [ ! -f "$GNUPGHOME/gpg-agent.conf" ]; then
  nix run --override-input parts/nixpkgs path:$(nix registry resolve nixpkgs) github:marksisson/gnupg
fi

# enable ssh auth via gpg-agent
export GNUPGHOME="$HOME/.config/gnupg"
export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)

# add github ssh host keys
mkdir -p $HOME/.ssh
ssh-keyscan github.com > $HOME/.ssh/known_hosts

[ "$(uname -s)" = "Darwin" ] && {
  # move files that nix-darwin will overwrite
  if [ -f /etc/nix/nix.custom.conf ]; then
    sudo mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
  fi
  if [ -f /etc/zshenv ]; then
    sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin
  fi

  DARWIN_CONFIGS=$(nix eval --json --impure --expr \
    'let flake = builtins.getFlake "git+ssh://git@github.com/marksisson/configurations"; in builtins.attrNames flake.outputs.darwinConfigurations' \
    | jq -r '.[]' | grep -v '^default$')

  # convert newline-separated list to an array
  mapfile -t DARWIN_CONFIGS_ARRAY <<< "$DARWIN_CONFIGS"

  echo "Select darwin configuration:"
  select DARWIN_CONFIG in "${DARWIN_CONFIGS_ARRAY[@]}"; do
    [[ -n $DARWIN_CONFIG ]] && break
    echo "Invalid selection, try again."
  done < /dev/tty

  # install darwin configuration
  if ! command -v darwin-rebuild &>/dev/null; then
    sudo nix run --override-input nixpkgs $(nix registry resolve nixpkgs) github:nix-darwin/nix-darwin#darwin-rebuild -- \
      switch --flake git+ssh://git@github.com/marksisson/configurations#${DARWIN_CONFIG}
  fi

  # restart nix daemon to pickup nix configuration changes
  sudo launchctl kickstart -k system/systems.determinate.nix-daemon
}

[ "$(uname -s)" = "Linux" ] && {
  # install nixos configuration
}

# install home-manager configuration
if ! command -v home-manager &>/dev/null; then
  HOME_CONFIGS=$(nix eval --json --impure --expr \
    'let flake = builtins.getFlake "git+ssh://git@github.com/marksisson/configurations"; in builtins.attrNames flake.outputs.homeConfigurations' \
    | jq -r '.[]' | grep -v '^default$')

  # convert newline-separated list to an array
  mapfile -t HOME_CONFIGS_ARRAY <<< "$HOME_CONFIGS"

  echo "Select home configuration:"
  select HOME_CONFIG in "${HOME_CONFIGS_ARRAY[@]}"; do
    [[ -n $HOME_CONFIG ]] && break
    echo "Invalid selection, try again."
  done < /dev/tty

  export NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1
  nix run --override-input nixpkgs $(nix registry resolve nixpkgs) github:nix-community/home-manager#home-manager -- \
    switch -b backup --flake git+ssh://git@github.com/marksisson/configurations#${HOME_CONFIG} --impure
fi

nix registry remove nixpkgs

echo "Done!"
