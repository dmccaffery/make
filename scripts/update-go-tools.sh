#!/usr/bin/env bash
# Copyright 2026 BitWise Media Group Ltd
# SPDX-License-Identifier: MIT
#
# Dependabot-style version updater for the pinned Go tools, with a cooldown.
#
# For every tool declared in fragments/gotools.mk this finds the highest released
# version on the Go module proxy that is at least COOLDOWN_DAYS old, and — if that
# is newer than the current .<tool>-version pin — rewrites the pin. The cooldown
# gives the wider ecosystem time to flag a malicious or broken release before we
# adopt it, exactly as Dependabot's `cooldown` does for the gomod ecosystem this
# replaces.
#
# Usage:
#   scripts/update-go-tools.sh            # apply updates in place
#   scripts/update-go-tools.sh --check    # report only; exit 1 if updates exist
#   COOLDOWN_DAYS=14 scripts/update-go-tools.sh
#
# Writes a machine-readable summary of applied bumps to $GITHUB_OUTPUT (key
# `updates`, one `tool old -> new` per line) when that variable is set, so the
# calling workflow can build a PR body.
set -euo pipefail

COOLDOWN_DAYS="${COOLDOWN_DAYS:-7}"
PROXY="${GOPROXY_BASE:-https://proxy.golang.org}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GOTOOLS_MK="$ROOT/fragments/gotools.mk"

check_only=false
[ "${1:-}" = "--check" ] && check_only=true

cutoff=$(( $(date -u +%s) - COOLDOWN_DAYS * 86400 ))

# Parse an RFC3339 timestamp (e.g. 2026-03-30T17:47:17Z) to epoch seconds,
# tolerating both GNU date (Linux/CI) and BSD date (local macOS).
to_epoch() {
	date -u -d "$1" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s
}

# The module path for proxy queries is the install path with any /cmd/... suffix
# removed (github.com/x/y/cmd/y -> github.com/x/y); paths without /cmd are modules
# already (github.com/x/y, .../v2).
module_of() { printf '%s' "${1%%/cmd/*}"; }

updates=""

# Each tool is `$(eval $(call gotool,<name>,<install-path>))` in gotools.mk.
while IFS=' ' read -r name pkg; do
	[ -n "$name" ] || continue
	pin_file="$ROOT/.${name}-version"
	[ -f "$pin_file" ] || { echo "skip $name: no $pin_file" >&2; continue; }
	current="$(cut -d' ' -f1 <"$pin_file")"
	module="$(module_of "$pkg")"

	# Released vMAJOR.MINOR.PATCH tags only — skip pre-releases and pseudo-versions.
	versions="$(curl -fsSL "$PROXY/$module/@v/list" 2>/dev/null | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V -r || true)"
	if [ -z "$versions" ]; then
		echo "skip $name ($module): no versions from proxy" >&2
		continue
	fi

	# Highest version whose publish time is at or before the cooldown cutoff; capture
	# the git commit SHA it resolves to (proxy Origin.Hash) so we pin @sha, not @tag.
	eligible=""; eligible_sha=""
	while IFS= read -r v; do
		info="$(curl -fsSL "$PROXY/$module/@v/$v.info" 2>/dev/null)" || continue
		published="$(printf '%s' "$info" | sed -n 's/.*"Time":"\([^"]*\)".*/\1/p')"
		[ -n "$published" ] || continue
		if [ "$(to_epoch "$published")" -le "$cutoff" ]; then
			eligible="$v"
			eligible_sha="$(printf '%s' "$info" | sed -n 's/.*"Hash":"\([0-9a-f]\{40\}\)".*/\1/p')"
			break
		fi
	done <<<"$versions"

	[ -n "$eligible" ] || { echo "skip $name: no version older than ${COOLDOWN_DAYS}d" >&2; continue; }
	[ -n "$eligible_sha" ] || { echo "skip $name: no commit sha for $eligible" >&2; continue; }

	# Only move forward: the eligible version must be strictly greater than the pin.
	newest="$(printf '%s\n%s\n' "$current" "$eligible" | sort -V -r | head -1)"
	if [ "$eligible" != "$current" ] && [ "$newest" = "$eligible" ]; then
		echo "update $name: $current -> $eligible"
		updates="${updates}${name} ${current} -> ${eligible}"$'\n'
		$check_only || printf '%s %s\n' "$eligible" "$eligible_sha" >"$pin_file"
	fi
done < <(grep -oE 'call gotool,[a-z0-9-]+,[^)]+' "$GOTOOLS_MK" | sed -E 's/call gotool,([a-z0-9-]+),(.+)/\1 \2/')

if [ -z "$updates" ]; then
	echo "all go tool pins are up to date (cooldown ${COOLDOWN_DAYS}d)"
	exit 0
fi

if [ -n "${GITHUB_OUTPUT:-}" ]; then
	{
		echo "updates<<EOF"
		printf '%s' "$updates"
		echo "EOF"
	} >>"$GITHUB_OUTPUT"
fi

# --check is a gate: non-zero means "updates are available".
$check_only && exit 1
exit 0
