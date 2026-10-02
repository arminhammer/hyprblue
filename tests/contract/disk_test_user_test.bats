#!/usr/bin/env bats
# Contract: iso/disk.toml (and iso/raw.toml if one exists) declares a login
# account, so `just run-vm-qcow2`/`run-vm-raw` boot to a usable SDDM login
# instead of a greeter with no account to select — unlike iso/iso.toml, BIB's
# qcow2/raw disk types never run Anaconda, so nothing else ever creates one.
#
# The password is asserted to be a crypt hash, never the literal plaintext:
# osbuild blueprints store a $6$/$5$/$2b$-prefixed string as-is in the image's
# shadow file, but anything else is stored as plaintext, and this repo commits
# disk.toml to git.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
DISK_TOML="${REPO_ROOT}/iso/disk.toml"
TEST_VM_PUBKEY="${REPO_ROOT}/iso/test-vm-ssh-key.pub"

@test "disk.toml: declares the test login account" {
	run grep -A5 '^\[\[customizations.user\]\]' "${DISK_TOML}"
	[ "$status" -eq 0 ]
	[[ "${output}" == *'name = "test"'* ]]
}

@test "disk.toml: the test account's password is stored as a crypt hash, not plaintext" {
	password_line="$(grep -A5 '^\[\[customizations.user\]\]' "${DISK_TOML}" | grep '^password')"
	[ -n "${password_line}" ]
	[[ "${password_line}" != *'"test"'* ]]

	# osbuild only treats a $6$/$5$/$2b$-prefixed value as a crypt hash;
	# anything else (including "test" itself) is stored as plaintext.
	run grep -qE 'password = "\$(6|5|2b)\$' <<<"${password_line}"
	[ "$status" -eq 0 ]
}

@test "disk.toml: the test account's key matches the committed test-vm-ssh-key.pub" {
	# Password auth needs an interactive prompt (or sshpass); a headless
	# automated test run needs key auth to actually be non-interactive.
	[ -f "${TEST_VM_PUBKEY}" ]
	pubkey_line="$(tr -d '\n' <"${TEST_VM_PUBKEY}")"

	key_line="$(grep -A5 '^\[\[customizations.user\]\]' "${DISK_TOML}" | grep '^key')"
	[ -n "${key_line}" ]
	[[ "${key_line}" == *"${pubkey_line}"* ]]
}

@test "disk.toml: the test account is in the wheel group" {
	run grep -A5 '^\[\[customizations.user\]\]' "${DISK_TOML}"
	[ "$status" -eq 0 ]
	[[ "${output}" == *'groups = ["wheel"]'* ]]
}
