#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Brave browser from the vendor RPM repository
###############################################################################
# Same third-party repository pattern as 30-tailscale.sh.example: add the
# vendor's repo file, install, then take the repo back out so the image ships no
# live third-party source.
#
# The RPM installs into /opt/brave.com, so /opt has to be a real directory; the
# Containerfile makes it one before this phase runs.
###############################################################################

echo "::group:: Install Brave"

dnf5 config-manager addrepo --overwrite \
	--from-repofile=https://brave-browser-rpm-release.s3.brave.com/brave-browser.repo
dnf5 install -y brave-browser

rm -f /etc/yum.repos.d/brave-browser.repo

echo "::endgroup::"
