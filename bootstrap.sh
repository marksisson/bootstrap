#!/usr/bin/env bash
set -euo pipefail

# prompt for sudo upfront
if ! sudo -n true 2>/dev/null; then
  printf "\033[92mRequesting sudo access...\n\033[0m"
  sudo -v < /dev/tty || { echo "Failed to get sudo access. Exiting."; exit 1; }
fi

# Keep sudo alive in background (refresh every 60s)
(while true; do sudo -n true; sleep 60; done) & SUDO_KEEPALIVE_PID=$!

# Make sure to kill the background process on exit
cleanup() { kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# install nix
if ! command -v nix &>/dev/null; then
  printf "\033[94mInstalling Nix...\n\033[0m"
  curl -fsSL https://install.determinate.systems/nix | sh -s -- install --no-confirm
fi

# make nix available to current script
if [ ! -n "${NIX_PROFILES:-}" ]; then
  . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
fi

# use local nixpkgs
if [ ! -n "${NIXPKGS:-}" ]; then
  printf "\033[94mInstalling canonical nixpkgs...\n\033[0m"
  export NIXPKGS=$(nix eval --raw --impure --expr 'let flake = builtins.getFlake "github:marksisson/parts"; in flake.inputs.nixpkgs.outPath')
fi

# add local nixpkgs to user registry
nix registry add nixpkgs $NIXPKGS

# install packages needed by remainder of script
if [ -z "${SCRIPT_IN_NIX_SHELL:-}" ]; then
  export SCRIPT_IN_NIX_SHELL=1
  cleanup # since script is not exiting (just exec'ing), manually cleanup sudo keepalive
  exec nix shell nixpkgs#bash nixpkgs#git nixpkgs#gnupg nixpkgs#jq --command bash "$@"
fi

# install gnupg configuration
export GNUPGHOME="$HOME/.config/gnupg"
if [ ! -f "$GNUPGHOME/gpg-agent.conf" ]; then
  printf "\033[94mInstalling gnupg configuration...\n\033[0m"
  nix run github:marksisson/gnupg
fi

# enable ssh auth via gpg-agent
if [[ "${SSH_AUTH_SOCK:-}" != *gpg-agent* ]]; then
  printf "\033[94mConfiguring ssh...\n\033[0m"
  export SSH_AUTH_SOCK=$(gpgconf --list-dirs agent-ssh-socket)

  # add github ssh host keys
  mkdir -p "$HOME/.ssh"
  ssh-keyscan -H github.com > $HOME/.ssh/known_hosts
fi

[ "$(uname -s)" = "Darwin" ] && {
  # install darwin configuration
  if ! command -v darwin-rebuild &>/dev/null; then
    # move files that nix-darwin will overwrite
    if [ -f /etc/nix/nix.custom.conf ]; then
      sudo mv /etc/nix/nix.custom.conf /etc/nix/nix.custom.conf.before-nix-darwin
    fi
    if [ -f /etc/zshenv ]; then
      sudo mv /etc/zshenv /etc/zshenv.before-nix-darwin
    fi

    printf "\033[94mRetrieving darwin configurations...\n\033[0m"
    DARWIN_CONFIGS=$(nix eval --json --impure --expr \
      'let flake = builtins.getFlake "git+ssh://git@github.com/marksisson/configurations"; in builtins.attrNames flake.outputs.darwinConfigurations' 2>/dev/null \
      | jq -r '.[]' | grep -v '^default$')

    # convert newline-separated list to an array
    mapfile -t DARWIN_CONFIGS_ARRAY <<< "$DARWIN_CONFIGS"

    printf "\033[94m\nSelect darwin configuration:\n\033[0m"
    select DARWIN_CONFIG in "${DARWIN_CONFIGS_ARRAY[@]}"; do
      [[ -n $DARWIN_CONFIG ]] && break
      printf "\033[91mInvalid selection, try again.\n\033[0m"
    done < /dev/tty

    echo
    sudo nix run --override-input nixpkgs $(nix registry resolve nixpkgs) github:nix-darwin/nix-darwin#darwin-rebuild -- \
      switch --flake git+ssh://git@github.com/marksisson/configurations#${DARWIN_CONFIG} 2>&1 | \
        awk '
          /^setting|^configuring/ { print "\033[34m" $0 "\033[0m"; next }
          { printf "\r\033[K\033[90m%s\033[0m", $0; fflush() }
        '
    echo
  fi

  # restart nix daemon to pickup nix configuration changes
  sudo launchctl kickstart -k system/systems.determinate.nix-daemon
}

[ "$(uname -s)" = "Linux" ] && {
  printf "\033[94mRetrieving nixos configurations...\n\033[0m"
  NIXOS_CONFIGS=$(nix eval --json --impure --expr \
    'let flake = builtins.getFlake "git+ssh://git@github.com/marksisson/configurations"; in builtins.attrNames flake.outputs.nixosConfigurations' 2>/dev/null \
    | jq -r '.[]' | grep -v '^default$')

  # convert newline-separated list to an array
  mapfile -t NIXOS_CONFIGS_ARRAY <<< "$NIXOS_CONFIGS"

  printf "\033[94m\nSelect nixos configuration:\n\033[0m"
  select NIXOS_CONFIG in "${NIXOS_CONFIGS_ARRAY[@]}"; do
    [[ -n $NIXOS_CONFIG ]] && break
    printf "\033[91mInvalid selection, try again.\n\033[0m"
  done < /dev/tty
  
  # install nixos configuration
  echo "NixOS install not yet implemented"
  exit 1
}

# install home-manager configuration
if ! command -v home-manager &>/dev/null; then
  printf "\033[94mRetrieving home configurations...\n\033[0m"
  HOME_CONFIGS=$(nix eval --json --impure --expr \
    'let flake = builtins.getFlake "git+ssh://git@github.com/marksisson/configurations"; in builtins.attrNames flake.outputs.homeConfigurations' 2>/dev/null \
    | jq -r '.[]' | grep -v '^default$')

  # convert newline-separated list to an array
  mapfile -t HOME_CONFIGS_ARRAY <<< "$HOME_CONFIGS"

  printf "\033[94m\nSelect home configuration:\n\033[0m"
  select HOME_CONFIG in "${HOME_CONFIGS_ARRAY[@]}"; do
    [[ -n $HOME_CONFIG ]] && break
    printf "\033[91mInvalid selection, try again.\n\033[0m"
  done < /dev/tty

  echo
  export NIXPKGS_ALLOW_UNFREE=1 NIXPKGS_ALLOW_BROKEN=1
  nix run --override-input nixpkgs $(nix registry resolve nixpkgs) github:nix-community/home-manager#home-manager -- \
    switch -b backup --flake git+ssh://git@github.com/marksisson/configurations#${HOME_CONFIG} --impure 2>&1 | \
      awk '
        /^Starting|^Activating/ { print "\033[34m" $0 "\033[0m"; next }
        { printf "\r\033[K\033[90m%s\033[0m", $0; fflush() }
      '
  echo
fi

# remove local nixpkgs from user registry
nix registry remove nixpkgs

printf "\033[92m\nDone!\n\033[0m"
