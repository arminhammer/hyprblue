#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Hyprland desktop
###############################################################################
# base-atomic ships no desktop at all, so this phase owns everything needed to
# make it boot into a working Hyprland session: the compositor/session/portal/
# polkit-agent packages, the desktop app set ML4W OS installs by default, SDDM
# as the display manager, ML4W's own dotfiles (fetched, not vendored — see
# below), fish as the default shell, Monofur Nerd Font as the default terminal
# font, and oh-my-posh as the shell prompt (also fetched, checksum-verified —
# no Fedora package or COPR exists for it). Kept separate from
# 20-packages-and-services.sh so the Hyprland package set is one
# self-contained, independently reviewable/removable phase.
#
# Every COPR and package name below was cross-checked against a live listing
# of the COPR's own packages or `dnf repoquery` against Fedora's own repos —
# not assumed from ML4W's dependency file. Two deliberate omissions from that
# file:
#   vlc                - lives in RPM Fusion, not enabled on this image.
#                         Enabling a third-party repo is a separate,
#                         image-wide decision this phase does not make alone.
#   gnome-themes-extra - retired; no current replacement found.
# A few more of ML4W's names are packages Fedora has since renamed (wget,
# vim, pkg-config, fontawesome-fonts, breeze); the lists below use the
# current names.
###############################################################################

# Source helper functions
# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

echo "::group:: Install Hyprland packages"

# The compositor itself, its session-launch wrapper, the screen-share portal,
# and the GUI polkit agent (GNOME supplied the last of those for free on the
# old GNOME base). Several more of ML4W's declared packages (kitty, nwg-look,
# qt6ct, cliphist) are also listed in its generic "packages" file but only
# actually resolve from this COPR, not Fedora's own repos.
copr_install_isolated "lionheartp/Hyprland" \
	hyprland hyprshutdown uwsm awww hyprsunset quickshell hyprland-guiutils \
	xdg-desktop-portal-hyprland hyprpolkitagent hyprpaper hyprlock hypridle \
	hyprpicker kitty cliphist nwg-look qt6ct

echo "::endgroup::"

echo "::group:: Install SwayNotificationCenter"

copr_install_isolated "erikreider/SwayNotificationCenter" SwayNotificationCenter

echo "::endgroup::"

echo "::group:: Install Nerd Fonts"

# che/nerd-fonts (an earlier source for JetBrainsMono) turned out to ship a
# single symbols-only fallback package, not per-family fonts — confirmed by
# reading its actual built RPM and spec, not assumed from ML4W's dependency
# file. aquacash5/nerd-fonts has real per-family packages for both: JetBrainsMono
# (ML4W's own default) and Monofur (this image's actual default; see the kitty
# patch below).
copr_install_isolated "aquacash5/nerd-fonts" jet-brains-mono-nerd-fonts monofur-nerd-fonts

echo "::endgroup::"

echo "::group:: Install Hyprland desktop packages"

dnf5 install -y \
	libnotify qt5-qtwayland qt6-qtwayland python3-pip python3-gobject \
	python3-devel python3-setuptools gtk3 gtk-layer-shell python3-i3ipc \
	pipx nm-connection-editor network-manager-applet fuse ImageMagick \
	NetworkManager-tui tesseract-langpack-eng fontawesome-fonts-all \
	qt5-qtgraphicaleffects qt6-qt5compat qt6-qtsvg qt6-qtvirtualkeyboard \
	qt6-qtmultimedia gvfs-mtp openssl-devel pkgconf-pkg-config gcc \
	gobject-introspection-devel cairo-gobject-devel gtk4 libadwaita-devel \
	lua wget2-wget curl git rsync unzip tar jq flatpak vim-enhanced \
	inotify-tools udisks2 gvfs udiskie rofi pavucontrol neovim blueman \
	nautilus gnome-text-editor firefox xdg-user-dirs xdg-desktop-portal-gtk \
	figlet fastfetch htop xclip zsh fzf brightnessctl tumbler slurp grim \
	breeze-icon-theme tesseract wl-clipboard btop cargo eza libsecret waybar \
	fish

echo "::endgroup::"

echo "::group:: Install SDDM"

# sddm, qt6-qtsvg, qt6-qtvirtualkeyboard, and qt6-qtmultimedia are already in
# Fedora's official repos, so this is a plain install with no COPR involved.
# Matches the exact package set ML4W's own ml4w-install-sddm script installs,
# plus sddm-breeze: Fedora's sddm package defaults Theme/Current to
# "01-breeze-fedora" but doesn't ship that theme itself — sddm-breeze does.
# Without it SDDM silently falls back to its embedded theme every start.
dnf5 install -y sddm sddm-breeze qt6-qtsvg qt6-qtvirtualkeyboard qt6-qtmultimedia

echo "::endgroup::"

echo "::group:: Enable Hyprland session services"

# Without this, the image boots to no login screen and no way to start a
# Hyprland session: base-atomic has no display manager at all.
systemctl enable sddm.service

echo "::endgroup::"

echo "::group:: Install ML4W dotfiles"

# Fetched rather than vendored: mylinuxforwork/dotfiles is ~47MB (mostly
# wallpaper images), and fetching a pinned tag keeps that weight out of this
# repository's permanent git history while staying exactly as reproducible.
# The tag matches this repo's own hyprland-dotfiles-stable.dotinst at the
# repo root. Seeds the same /etc/skel that custom/config/ and custom/files/
# use, just from fetched content instead of committed content.
ML4W_DOTFILES_TAG="2.15.1"
ML4W_DOTFILES_TMP="$(mktemp -d)"
trap 'rm -rf "${ML4W_DOTFILES_TMP}"' EXIT

curl --fail --retry 3 --silent --show-error --location \
	--output "${ML4W_DOTFILES_TMP}/dotfiles.tar.gz" \
	"https://github.com/mylinuxforwork/dotfiles/archive/refs/tags/${ML4W_DOTFILES_TAG}.tar.gz"

tar -xzf "${ML4W_DOTFILES_TMP}/dotfiles.tar.gz" -C "${ML4W_DOTFILES_TMP}"

DOTFILES_SRC="${ML4W_DOTFILES_TMP}/dotfiles-${ML4W_DOTFILES_TAG}/dotfiles"

# ML4W's autostart execs /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1,
# but the polkit-gnome package that provided it no longer exists in Fedora's
# repos (verified with `dnf repoquery`). hyprpolkitagent, installed above from
# lionheartp/Hyprland, is this image's actual polkit agent.
sed -i \
	's#/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1#hyprpolkitagent#' \
	"${DOTFILES_SRC}/.config/hypr/conf/autostart.lua"

# ML4W's kitty.conf defaults to JetBrainsMono Nerd Font; both fonts are
# installed above, but Monofur is this image's actual default terminal font.
sed -i \
	's/^font_family.*/font_family                 Monofur Nerd Font/' \
	"${DOTFILES_SRC}/.config/kitty/kitty.conf"

# ML4W's 20-customization.fish calls $HOME/.local/bin/oh-my-posh, the path its
# own per-user ohmyposh.dev/install.sh installer uses. This image installs the
# binary system-wide at /usr/bin instead (see below), so the hardcoded path
# would otherwise be a command-not-found on every interactive fish session.
# zen.toml itself needs no separate fetch — it's already part of this archive.
sed -i \
	's#\$HOME/\.local/bin/oh-my-posh#oh-my-posh#' \
	"${DOTFILES_SRC}/.config/fish/conf.d/20-customization.fish"

mkdir -p /etc/skel/.config
cp -a "${DOTFILES_SRC}/.config/." /etc/skel/.config/
cp -a "${DOTFILES_SRC}/.Xresources" "${DOTFILES_SRC}/.bashrc" \
	"${DOTFILES_SRC}/.gtkrc-2.0" "${DOTFILES_SRC}/.zshrc" /etc/skel/

rm -rf "${ML4W_DOTFILES_TMP}"
trap - EXIT

echo "::endgroup::"

echo "::group:: Set the default shell to fish"

# Only changes /etc/default/useradd's SHELL= line for accounts created after
# this (including the one Anaconda's installer creates) — never an existing
# account's shell.
useradd -D -s /usr/bin/fish

echo "::endgroup::"

echo "::group:: Install oh-my-posh"

# oh-my-posh has no Fedora package or COPR; its own release binary, with a
# detached checksums.txt to verify against, is the standard install method.
POSH_VERSION="v31.3.0"
POSH_TMP="$(mktemp -d)"
trap 'rm -rf "${POSH_TMP}"' EXIT

curl --fail --retry 3 --silent --show-error --location \
	--output "${POSH_TMP}/posh-linux-amd64" \
	"https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/${POSH_VERSION}/posh-linux-amd64"
curl --fail --retry 3 --silent --show-error --location \
	--output "${POSH_TMP}/checksums.txt" \
	"https://github.com/JanDeDobbeleer/oh-my-posh/releases/download/${POSH_VERSION}/checksums.txt"

expected_sha256="$(grep '  posh-linux-amd64$' "${POSH_TMP}/checksums.txt" | cut -d' ' -f1)"
actual_sha256="$(sha256sum "${POSH_TMP}/posh-linux-amd64" | cut -d' ' -f1)"
if [[ -z "${expected_sha256}" || "${expected_sha256}" != "${actual_sha256}" ]]; then
	echo "ERROR: oh-my-posh download checksum mismatch" >&2
	exit 1
fi

install -D -m 0755 "${POSH_TMP}/posh-linux-amd64" /usr/bin/oh-my-posh

rm -rf "${POSH_TMP}"
trap - EXIT

echo "::endgroup::"
