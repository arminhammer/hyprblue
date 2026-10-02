#!/usr/bin/env bats
# Unit tests for `_build-bib`, the recipe that converts a container image into
# a qcow2/raw/iso disk with Bootc Image Builder.
#
# Exercised against a sandbox copy of the Justfile with `sudo` and `podman`
# stubbed: `sudo` execs its argv directly (no real privilege escalation
# needed in a test), and `podman` fakes just enough of `inspect`/`images`/
# `run` to satisfy _rootful_load_image and to drop fixture files where BIB's
# `-v BUILDTMP:/output` mount would land them — so the real `mkdir`/`mv`/
# `rmdir` in _build-bib run for real against real files, which is exactly
# where the bug this file guards against lives.
#
# Run with: bats tests/template/justfile-build-bib_test.bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}/../.."

setup() {
	if ! command -v just &>/dev/null; then
		skip "just is not installed"
	fi

	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/justfile-build-bib.${BATS_TEST_NUMBER:-0}.$$"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	SANDBOX="${TEST_ROOT}/repo"
	PODMAN_LOG="${TEST_ROOT}/logs/podman.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${SANDBOX}"
	cp "${REPO_ROOT}/Justfile" "${SANDBOX}/Justfile"
	mkdir -p "${SANDBOX}/iso"
	printf '[[customizations.filesystem]]\nmountpoint = "/"\n\n[[customizations.user]]\nname = "test"\nkey = "__TEST_VM_SSH_PUBLIC_KEY__"\n' >"${SANDBOX}/iso/disk.toml"

	CONFIG_MOUNT_LOG="${TEST_ROOT}/logs/config-mount.log"
	export PATH="${STUB_BIN}:${PATH}"
	export PODMAN_LOG CONFIG_MOUNT_LOG
	# _rootful_load_image no-ops entirely when it believes it is already
	# running under sudo — sidesteps the hardcoded /usr/bin/sudo call inside
	# the separate `sudoif` dispatcher (a different code path than the bare
	# `sudo` calls in _build-bib this suite is actually about) without having
	# to fake real root.
	export SUDO_USER="test"
	# The fixture content the fake BIB run below drops into the mounted
	# output directory, so a test can assert the *new* build's content won by
	# checking for the version this run tags its fixture with.
	export STUB_BIB_CONTENT="build-b"

	cat >"${STUB_BIN}/sudo" <<'EOF'
#!/usr/bin/env bash
exec "$@"
EOF
	chmod +x "${STUB_BIN}/sudo"

	# Only the two podman calls _build-bib itself needs are faked: `run`
	# (BIB itself, faked by writing a fixture qcow2/disk.qcow2 into whatever
	# host path is bind-mounted at /output) and `inspect`/`images` for a
	# no-op _rootful_load_image is already bypassed via SUDO_USER above, so
	# those never fire in this suite.
	cat >"${STUB_BIN}/podman" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"${PODMAN_LOG}"
if [[ "\$1" == "run" ]]; then
	args=("\$@")
	for i in "\${!args[@]}"; do
		if [[ "\${args[\$i]}" == -v && "\${args[\$((i+1))]}" == *:/output ]]; then
			host_dir="\${args[\$((i+1))]%%:/output}"
			mkdir -p "\${host_dir}/qcow2"
			printf '%s' "\${STUB_BIB_CONTENT}" >"\${host_dir}/qcow2/disk.qcow2"
		fi
		if [[ "\${args[\$i]}" == -v && "\${args[\$((i+1))]}" == *:/config.toml:ro ]]; then
			config_host="\${args[\$((i+1))]%%:/config.toml:ro}"
			cp "\${config_host}" "${CONFIG_MOUNT_LOG}"
		fi
	done
fi
exit 0
EOF
	chmod +x "${STUB_BIN}/podman"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

run_build_qcow2() {
	run bash -c "cd '${SANDBOX}' && just build-qcow2 localhost/hyprblue stable"
}

@test "build-qcow2: succeeds on a clean output directory" {
	run_build_qcow2
	[ "$status" -eq 0 ]
	[ -f "${SANDBOX}/output/qcow2/disk.qcow2" ]
}

@test "build-qcow2: is idempotent — a second run does not fail on stale output from the first" {
	run_build_qcow2
	[ "$status" -eq 0 ]

	STUB_BIB_CONTENT="build-c" run_build_qcow2
	[ "$status" -eq 0 ]
	[ "$(cat "${SANDBOX}/output/qcow2/disk.qcow2")" = "build-c" ]
}

@test "build-qcow2: a stale output/qcow2/ from an unrelated earlier build does not block a fresh one" {
	# Reproduces the reported bug directly: output/qcow2/ pre-populated as if
	# by an old build, before _build-bib ever runs.
	mkdir -p "${SANDBOX}/output/qcow2"
	printf 'stale-build' >"${SANDBOX}/output/qcow2/disk.qcow2"

	run_build_qcow2
	[ "$status" -eq 0 ]
	[ "$(cat "${SANDBOX}/output/qcow2/disk.qcow2")" = "build-b" ]
}

@test "build-qcow2: generates a local test VM SSH key, never committed" {
	# output/ is gitignored wholesale — the key must land there, never under
	# iso/ (the committed-blueprint seam) or anywhere else that could end up
	# in a commit.
	run_build_qcow2
	[ "$status" -eq 0 ]

	[ -f "${SANDBOX}/output/test-vm-ssh-key" ]
	[ -f "${SANDBOX}/output/test-vm-ssh-key.pub" ]
	run grep -q "PRIVATE KEY" "${SANDBOX}/output/test-vm-ssh-key"
	[ "$status" -eq 0 ]
}

@test "build-qcow2: substitutes the generated public key into disk.toml's placeholder before handing it to BIB" {
	run_build_qcow2
	[ "$status" -eq 0 ]

	pubkey="$(cat "${SANDBOX}/output/test-vm-ssh-key.pub")"
	[ -f "${CONFIG_MOUNT_LOG}" ]
	run grep -qF "__TEST_VM_SSH_PUBLIC_KEY__" "${CONFIG_MOUNT_LOG}"
	[ "$status" -ne 0 ]
	run grep -qF "${pubkey}" "${CONFIG_MOUNT_LOG}"
	[ "$status" -eq 0 ]

	# The committed disk.toml itself is untouched — only the materialized copy
	# handed to BIB carries the real key.
	run grep -qF "__TEST_VM_SSH_PUBLIC_KEY__" "${SANDBOX}/iso/disk.toml"
	[ "$status" -eq 0 ]
}

@test "build-qcow2: reuses the same local key across runs instead of regenerating it" {
	run_build_qcow2
	[ "$status" -eq 0 ]
	first_key="$(cat "${SANDBOX}/output/test-vm-ssh-key.pub")"

	run_build_qcow2
	[ "$status" -eq 0 ]
	[ "$(cat "${SANDBOX}/output/test-vm-ssh-key.pub")" = "${first_key}" ]
}
