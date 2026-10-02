#!/usr/bin/env bats
# Contract: the base image carries no desktop of its own. Hyprland is
# installed and made bootable entirely by build/20-packages-and-services.sh
# (Hyprland/uwsm/portal/polkit-agent from lionheartp/Hyprland, SDDM from
# Fedora's own repos, sddm.service enabled). A base that already ships a
# desktop (GNOME's silverblue, KDE's kinoite, ...) would fight that: two
# session stacks, two display managers, wasted layers. This test only checks
# the FROM line names a no-desktop base; it does not re-verify the Hyprland
# package/service wiring, which tests/template/20-packages-and-services_test.bats
# owns.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
CONTAINERFILE="${REPO_ROOT}/Containerfile"

# The final FROM line is the base actually built on: the file also has FROM
# lines for the ctx/common/brew stages above it, which this must ignore.
base_image_from_line() {
	grep -E '^FROM ' "${CONTAINERFILE}" | tail -1
}

@test "base image: the final FROM line does not pull in a bundled desktop" {
	run base_image_from_line
	[ "$status" -eq 0 ]
	[ -n "${output}" ]

	# fedora-ostree-desktops ships one variant per desktop (silverblue=GNOME,
	# kinoite=KDE, sericea=Sway, ...); base-atomic is the only one with none.
	[[ "${output}" != *"/silverblue"* ]]
	[[ "${output}" != *"/kinoite"* ]]
	[[ "${output}" != *"/sericea"* ]]
}

@test "base image: the final FROM line targets the no-desktop base-atomic image" {
	run base_image_from_line
	[ "$status" -eq 0 ]
	[[ "${output}" == *"fedora-ostree-desktops/base-atomic"* ]]
}
