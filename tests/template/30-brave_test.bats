#!/usr/bin/env bats
# Unit tests for build/30-brave.sh.
#
# Run with: bats tests/template/30-brave_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SCRIPT="${REPO_ROOT}/build/30-brave.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/30-brave.${BATS_TEST_NUMBER:-0}.$$"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs"

	cat >"${STUB_BIN}/dnf5" <<EOF2
#!/usr/bin/bash
printf '%s\n' "\$*" >> "${DNF5_LOG}"
exit 0
EOF2
	chmod +x "${STUB_BIN}/dnf5"
	export PATH="${STUB_BIN}:${PATH}"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

@test "30-brave: adds the vendor repo file, installs brave-browser, in that order" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${#calls[@]}" -eq 2 ]
	[ "${calls[0]}" = "config-manager addrepo --overwrite --from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo" ]
	[ "${calls[1]}" = "install -y brave-browser" ]
}

@test "30-brave: removes the vendor repo file afterwards" {
	run grep -n 'rm -f /etc/yum.repos.d/brave-browser.repo' "${SCRIPT}"
	[ "$status" -eq 0 ]
}
