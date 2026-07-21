#!/bin/zsh

set -euo pipefail

readonly expected_group="group.com.21media.haloapp"
readonly app_path="${1:-}"

if [[ -z "${app_path}" || ! -d "${app_path}" ]]; then
    print -u2 "Usage: $0 /path/to/Flow.app"
    exit 64
fi

readonly extension_path="${app_path}/PlugIns/FlowShareExtension.appex"
if [[ ! -d "${extension_path}" ]]; then
    print -u2 "Missing embedded Share Extension: ${extension_path}"
    exit 65
fi

readonly scratch_directory="$(mktemp -d "${TMPDIR:-/tmp}/halo-signing-check.XXXXXX")"
trap 'rm -rf "${scratch_directory}"' EXIT

verify_bundle() {
    local bundle_path="$1"
    local bundle_label="$2"
    local signed_entitlements="${scratch_directory}/${bundle_label}-signed-entitlements.plist"
    local provision_entitlements="${scratch_directory}/${bundle_label}-provision.plist"
    local embedded_profile="${bundle_path}/embedded.mobileprovision"

    if ! /usr/bin/codesign --display --entitlements :- "${bundle_path}" >"${signed_entitlements}" 2>/dev/null; then
        print -u2 "Unable to read signed entitlements from ${bundle_label}."
        return 1
    fi

    if ! /usr/libexec/PlistBuddy -c "Print :com.apple.security.application-groups" \
        "${signed_entitlements}" 2>/dev/null | /usr/bin/grep -Fq "${expected_group}"; then
        print -u2 "${bundle_label} signature is missing App Group ${expected_group}."
        return 1
    fi

    if [[ ! -f "${embedded_profile}" ]]; then
        print -u2 "${bundle_label} has no embedded provisioning profile; this verifier expects a device build."
        return 1
    fi

    if ! /usr/bin/security cms -D -i "${embedded_profile}" >"${provision_entitlements}" 2>/dev/null; then
        print -u2 "Unable to decode ${bundle_label}'s provisioning profile."
        return 1
    fi

    if ! /usr/libexec/PlistBuddy -c "Print :Entitlements:com.apple.security.application-groups" \
        "${provision_entitlements}" 2>/dev/null | /usr/bin/grep -Fq "${expected_group}"; then
        print -u2 "${bundle_label} provisioning profile does not authorize App Group ${expected_group}."
        return 1
    fi

    print "Verified ${bundle_label}: signature and profile authorize ${expected_group}."
}

verify_bundle "${app_path}" "Halo"
verify_bundle "${extension_path}" "HaloShareExtension"

print "App Group signing is valid for Halo and its Share Extension."
