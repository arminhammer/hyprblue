#!/usr/bin/env bats
# Unit tests for build/70-hyprland.sh.
#
# This phase owns everything needed to make base-atomic (no bundled desktop)
# boot into a working Hyprland session: the Hyprland/session/portal/polkit
# packages, the desktop app set ML4W OS ships by default, and SDDM as the
# display manager, each from the COPR or official repo it actually lives in
# (verified with `skopeo`/`dnf repoquery`, not guessed). Kept separate from
# 20-packages-and-services.sh so the Hyprland package set is one
# self-contained, independently reviewable/removable phase.
#
# Run with: bats tests/template/70-hyprland_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_SRC="${REPO_ROOT}/build/70-hyprland.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/70-hyprland.${BATS_TEST_NUMBER:-0}.$$"
	SANDBOX="${TEST_ROOT}/root"
	CTX="${SANDBOX}/ctx"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	SCRIPT="${TEST_ROOT}/70-hyprland.sh"

	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"
	CURL_LOG="${TEST_ROOT}/logs/curl.log"
	USERADD_LOG="${TEST_ROOT}/logs/useradd.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${CTX}/build"

	# The real helper library is sourced verbatim so a syntax break there fails
	# this suite too.
	cp "${REPO_ROOT}/build/copr-helpers.sh" "${CTX}/build/copr-helpers.sh"

	sed \
		-e "s#/ctx/#${CTX}/#g" \
		-e "s#/etc/skel#${SANDBOX}/etc/skel#g" \
		-e "s#/usr/bin/oh-my-posh#${SANDBOX}/usr/bin/oh-my-posh#g" \
		"${BUILD_SRC}" >"${SCRIPT}"

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SYSTEMCTL_LOG CURL_LOG USERADD_LOG

	for tool in dnf5 systemctl useradd; do
		local log_var
		log_var="$(printf '%s' "${tool}" | tr '[:lower:]' '[:upper:]')_LOG"
		cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "\${${log_var}}"
exit 0
EOF
		chmod +x "${STUB_BIN}/${tool}"
	done

	# curl is stubbed to drop a small fixture tarball at whatever --output path
	# was requested, so the real tar/cp downstream of it run against real
	# content — the extraction path-stripping is exactly the kind of thing a
	# pure call-log stub would never catch a bug in. tar/cp themselves are the
	# genuine binaries.
	FIXTURE_SRC="${TEST_ROOT}/fixture-src"
	FIXTURE_TARBALL="${TEST_ROOT}/fixture-dotfiles.tar.gz"
	mkdir -p "${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.config/hypr/conf"
	printf 'require("conf.autostart")\n' >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.config/hypr/hyprland.lua"
	cat >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.config/hypr/conf/autostart.lua" <<'EOF'
hl.on("hyprland.start", function ()
    hl.exec_cmd("/usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1")
end)
EOF
	mkdir -p "${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.config/kitty"
	cat >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.config/kitty/kitty.conf" <<'EOF'
# Configuration
font_family                 JetBrainsMono Nerd Font
font_size                   12
EOF
	mkdir -p "${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.config/fish/conf.d"
	cat >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.config/fish/conf.d/20-customization.fish" <<'EOF'
# -----------------------------------------------------
# Prompt
# -----------------------------------------------------
eval "$($HOME/.local/bin/oh-my-posh init fish --config $HOME/.config/ohmyposh/zen.toml)"
# eval "$($HOME/.local/bin/oh-my-posh init fish --config $HOME/.config/ohmyposh/EDM115-newline.omp.json)"
EOF
	printf 'export EDITOR=nvim\n' >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.bashrc"
	printf 'export EDITOR=nvim\n' >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.zshrc"
	printf '# gtkrc\n' >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.gtkrc-2.0"
	printf '! Xresources\n' >"${FIXTURE_SRC}/dotfiles-2.15.1/dotfiles/.Xresources"
	tar -czf "${FIXTURE_TARBALL}" -C "${FIXTURE_SRC}" dotfiles-2.15.1

	# A second, independent fetch: the oh-my-posh binary release (a bare binary,
	# not a tarball) plus its checksums.txt. A real fixture binary, not just a
	# call log, so the checksum-verification and install logic in the script
	# actually run for real against it.
	POSH_BIN_SRC="${TEST_ROOT}/posh-bin-src/posh-linux-amd64"
	mkdir -p "$(dirname "${POSH_BIN_SRC}")"
	printf '#!/usr/bin/bash\necho "fixture oh-my-posh"\n' >"${POSH_BIN_SRC}"
	chmod +x "${POSH_BIN_SRC}"
	POSH_BIN_SHA256="$(sha256sum "${POSH_BIN_SRC}" | cut -d' ' -f1)"
	FIXTURE_POSH_CHECKSUMS="${TEST_ROOT}/fixture-checksums.txt"
	cat >"${FIXTURE_POSH_CHECKSUMS}" <<EOF
${POSH_BIN_SHA256}  posh-linux-amd64
0000000000000000000000000000000000000000000000000000000000000000  posh-darwin-amd64
EOF

	cat >"${STUB_BIN}/curl" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "${CURL_LOG}"
args=("\$@")
url="\${args[-1]}"
for i in "\${!args[@]}"; do
	if [[ "\${args[\$i]}" == "--output" ]]; then
		out="\${args[\$((i+1))]}"
		case "\${url}" in
			*dotfiles/archive/refs/tags*) cp "${FIXTURE_TARBALL}" "\${out}" ;;
			*checksums.txt) cp "${FIXTURE_POSH_CHECKSUMS}" "\${out}" ;;
			*posh-linux-amd64) cp "${POSH_BIN_SRC}" "\${out}" ;;
			*) echo "unexpected curl fixture request: \${url}" >&2; exit 1 ;;
		esac
	fi
done
exit 0
EOF
	chmod +x "${STUB_BIN}/curl"
	export FIXTURE_TARBALL POSH_BIN_SRC FIXTURE_POSH_CHECKSUMS
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

@test "70-hyprland: sandbox rewrite left no writes to the host filesystem" {
	run grep -nE '(^|[^-[:alnum:]])/ctx/|[^-[:alnum:]]/etc/skel|[^-[:alnum:]]/usr/bin/oh-my-posh' "${SCRIPT}"
	[ "$status" -ne 0 ]

	grep -q "source ${CTX}/build/copr-helpers.sh" "${SCRIPT}"
}

@test "70-hyprland: completes successfully" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "70-hyprland: emits GitHub Actions group markers" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"::group:: Install Hyprland packages"* ]]
	[[ "$output" == *"::group:: Install SwayNotificationCenter"* ]]
	[[ "$output" == *"::group:: Install Nerd Fonts"* ]]
	[[ "$output" == *"::group:: Install Hyprland desktop packages"* ]]
	[[ "$output" == *"::group:: Install SDDM"* ]]
	[[ "$output" == *"::group:: Enable Hyprland session services"* ]]
	[[ "$output" == *"::group:: Install ML4W dotfiles"* ]]
	[[ "$output" == *"::group:: Set the default shell to fish"* ]]
	[[ "$output" == *"::group:: Install oh-my-posh"* ]]
	[[ "$output" == *"::endgroup::"* ]]
}

@test "70-hyprland: installs the Hyprland package set from lionheartp/Hyprland in isolation" {
	# Every name here was cross-checked against a live listing of the COPR's
	# packages (copr.fedorainfracloud.org/api_3/package/list) rather than
	# assumed from ML4W's dependency file — several (kitty, nwg-look, qt6ct,
	# cliphist) are also declared in ML4W's generic "packages" list but only
	# actually resolve from this COPR, not Fedora's own repos.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[0]}" = "-y copr enable lionheartp/Hyprland" ]
	[ "${calls[1]}" = "-y copr disable lionheartp/Hyprland" ]
	[ "${calls[2]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:lionheartp:Hyprland hyprland hyprshutdown uwsm awww hyprsunset quickshell hyprland-guiutils xdg-desktop-portal-hyprland hyprpolkitagent hyprpaper hyprlock hypridle hyprpicker kitty cliphist nwg-look qt6ct" ]
}

@test "70-hyprland: installs SwayNotificationCenter from erikreider/SwayNotificationCenter in isolation" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[3]}" = "-y copr enable erikreider/SwayNotificationCenter" ]
	[ "${calls[4]}" = "-y copr disable erikreider/SwayNotificationCenter" ]
	[ "${calls[5]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:erikreider:SwayNotificationCenter SwayNotificationCenter" ]
}

@test "70-hyprland: installs JetBrainsMono and Monofur Nerd Fonts from aquacash5/nerd-fonts in isolation" {
	# che/nerd-fonts (the earlier source for JetBrainsMono) turned out to ship a
	# single symbols-only fallback package, not per-family fonts — confirmed by
	# reading its actual built RPM and spec file, not assumed from ML4W's
	# dependency file this time. aquacash5/nerd-fonts has real per-family
	# packages (checked against a live build listing) for both.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[6]}" = "-y copr enable aquacash5/nerd-fonts" ]
	[ "${calls[7]}" = "-y copr disable aquacash5/nerd-fonts" ]
	[ "${calls[8]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:aquacash5:nerd-fonts jet-brains-mono-nerd-fonts monofur-nerd-fonts" ]
}

@test "70-hyprland: installs the desktop app set from Fedora's own repos" {
	# vlc (RPM Fusion) and gnome-themes-extra (retired, no replacement found)
	# are deliberately dropped from ML4W's list: RPM Fusion is a separate,
	# image-wide decision this phase does not make on its own. wget, vim,
	# pkg-config, fontawesome-fonts, and breeze are ML4W's names for packages
	# Fedora has since renamed; the install list below uses the current names
	# (verified with `dnf repoquery`).
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[9]}" = "install -y libnotify qt5-qtwayland qt6-qtwayland python3-pip python3-gobject python3-devel python3-setuptools gtk3 gtk-layer-shell python3-i3ipc pipx nm-connection-editor network-manager-applet fuse ImageMagick NetworkManager-tui tesseract-langpack-eng fontawesome-fonts-all qt5-qtgraphicaleffects qt6-qt5compat qt6-qtsvg qt6-qtvirtualkeyboard qt6-qtmultimedia gvfs-mtp openssl-devel pkgconf-pkg-config gcc gobject-introspection-devel cairo-gobject-devel gtk4 libadwaita-devel lua wget2-wget curl git rsync unzip tar jq flatpak vim-enhanced inotify-tools udisks2 gvfs udiskie rofi pavucontrol neovim blueman nautilus gnome-text-editor firefox xdg-user-dirs xdg-desktop-portal-gtk figlet fastfetch htop xclip zsh fzf brightnessctl tumbler slurp grim breeze-icon-theme tesseract wl-clipboard btop cargo eza libsecret waybar fish" ]
}

@test "70-hyprland: installs SDDM and its Qt6 companions from Fedora's own repos" {
	# Matches the exact package set ML4W's own ml4w-install-sddm script installs,
	# plus sddm-breeze: Fedora's sddm package defaults Theme/Current to
	# "01-breeze-fedora" (baked into its shipped /etc/sddm.conf as a commented
	# default), but doesn't ship that theme itself — sddm-breeze does (verified
	# with `dnf repoquery -l sddm-breeze`). Without it SDDM falls back to its
	# embedded theme and logs "doesn't exist" on every start.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[10]}" = "install -y sddm sddm-breeze qt6-qtsvg qt6-qtvirtualkeyboard qt6-qtmultimedia" ]
}

@test "70-hyprland: makes exactly the expected dnf5 calls, in order, with nothing extra" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${#calls[@]}" -eq 11 ]
}

@test "70-hyprland: enables sddm.service" {
	# base-atomic has no display manager at all (GDM shipped with the GNOME
	# base this template used to build on). Without this, the image boots to
	# no login screen and no way to start a Hyprland session.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${SYSTEMCTL_LOG}"
	[ "${#calls[@]}" -eq 1 ]
	[ "${calls[0]}" = "enable sddm.service" ]
}

@test "70-hyprland: fetches the pinned ML4W dotfiles tag" {
	# Pinned so a rebuild is reproducible and matches the version this repo's
	# own hyprland-dotfiles-stable.dotinst at the repo root names.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${CURL_LOG}"
	[[ "${calls[0]}" == *"https://github.com/mylinuxforwork/dotfiles/archive/refs/tags/2.15.1.tar.gz"* ]]
	[[ "${calls[0]}" == *"--output "* ]]
}

@test "70-hyprland: makes exactly the expected curl calls, with nothing extra" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${CURL_LOG}"
	[ "${#calls[@]}" -eq 3 ]
}

@test "70-hyprland: seeds /etc/skel/.config from the fetched dotfiles" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ -f "${SANDBOX}/etc/skel/.config/hypr/hyprland.lua" ]
	[ -f "${SANDBOX}/etc/skel/.config/hypr/conf/autostart.lua" ]
}

@test "70-hyprland: seeds the /etc/skel root dotfiles from the fetched archive" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ -f "${SANDBOX}/etc/skel/.bashrc" ]
	[ -f "${SANDBOX}/etc/skel/.zshrc" ]
	[ -f "${SANDBOX}/etc/skel/.gtkrc-2.0" ]
	[ -f "${SANDBOX}/etc/skel/.Xresources" ]
}

@test "70-hyprland: patches the stale polkit-gnome autostart line to the installed polkit agent" {
	# ML4W's autostart.lua execs /usr/lib/polkit-gnome/polkit-gnome-authentication-agent-1,
	# but the polkit-gnome package that provided it no longer exists in Fedora's
	# repos (verified with `dnf repoquery`). hyprpolkitagent, already installed
	# above from lionheartp/Hyprland, is this image's actual polkit agent.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	autostart="${SANDBOX}/etc/skel/.config/hypr/conf/autostart.lua"
	[ -f "${autostart}" ]
	run grep -q "polkit-gnome" "${autostart}"
	[ "$status" -ne 0 ]
	grep -q "hyprpolkitagent" "${autostart}"
}

@test "70-hyprland: patches kitty's default font to Monofur Nerd Font" {
	# ML4W's kitty.conf defaults to JetBrainsMono Nerd Font; both fonts are
	# installed above, but Monofur is what this image sets as the actual
	# default terminal/shell font.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	kitty_conf="${SANDBOX}/etc/skel/.config/kitty/kitty.conf"
	[ -f "${kitty_conf}" ]
	run grep -q "JetBrainsMono Nerd Font" "${kitty_conf}"
	[ "$status" -ne 0 ]
	grep -q "^font_family.*Monofur Nerd Font" "${kitty_conf}"
}

@test "70-hyprland: sets fish as the default shell for new accounts" {
	# useradd -D -s only changes /etc/default/useradd's SHELL= line for
	# accounts created after this (including the one Anaconda's installer
	# creates); it never touches an existing account's shell.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${USERADD_LOG}"
	[ "${#calls[@]}" -eq 1 ]
	[ "${calls[0]}" = "-D -s /usr/bin/fish" ]
}

@test "70-hyprland: installs oh-my-posh from its pinned GitHub release, checksum-verified" {
	# oh-my-posh has no Fedora package or COPR; its own release binary, with a
	# detached checksums.txt to verify against, is the standard install method
	# (ML4W's own post-fedora.sh uses the same release, just per-user via
	# ohmyposh.dev/install.sh rather than baked system-wide here).
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	posh_bin="${SANDBOX}/usr/bin/oh-my-posh"
	[ -f "${posh_bin}" ]
	[ -x "${posh_bin}" ]
	diff "${posh_bin}" "${POSH_BIN_SRC}"
}

@test "70-hyprland: fails when the downloaded oh-my-posh binary's checksum does not match" {
	# Regression guard for the checksum check itself: without this test, a
	# script that fetches checksums.txt but never actually compares it would
	# pass every other test in this file.
	cat >"${STUB_BIN}/curl" <<EOF
#!/usr/bin/bash
args=("\$@")
url="\${args[-1]}"
for i in "\${!args[@]}"; do
	if [[ "\${args[\$i]}" == "--output" ]]; then
		out="\${args[\$((i+1))]}"
		case "\${url}" in
			*dotfiles/archive/refs/tags*) cp "${FIXTURE_TARBALL}" "\${out}" ;;
			*checksums.txt) printf '%s\n' "0000000000000000000000000000000000000000000000000000000000000000  posh-linux-amd64" >"\${out}" ;;
			*posh-linux-amd64) cp "${POSH_BIN_SRC}" "\${out}" ;;
		esac
	fi
done
exit 0
EOF
	chmod +x "${STUB_BIN}/curl"

	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "70-hyprland: points 20-customization.fish's oh-my-posh call at the installed system binary" {
	# ML4W's own line calls $HOME/.local/bin/oh-my-posh, the path its per-user
	# ohmyposh.dev/install.sh installer uses. This image installs the binary
	# system-wide at /usr/bin instead (see above), so that hardcoded path
	# would otherwise be a command-not-found on every interactive fish session.
	# zen.toml itself needs no separate fetch — it's already part of the ML4W
	# dotfiles archive fetched above.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	customization="${SANDBOX}/etc/skel/.config/fish/conf.d/20-customization.fish"
	[ -f "${customization}" ]
	run grep -q '\$HOME/.local/bin/oh-my-posh' "${customization}"
	[ "$status" -ne 0 ]
	grep -q 'oh-my-posh init fish --config \$HOME/.config/ohmyposh/zen.toml' "${customization}"
}

@test "70-hyprland: sources copr-helpers.sh so copr_install_isolated is available" {
	cat >>"${SCRIPT}" <<'EOF'
declare -F copr_install_isolated >/dev/null && echo "HELPER_PRESENT"
EOF
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"HELPER_PRESENT"* ]]
}

@test "70-hyprland: fails fast when copr-helpers.sh is missing from the context" {
	rm -f "${CTX}/build/copr-helpers.sh"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}
