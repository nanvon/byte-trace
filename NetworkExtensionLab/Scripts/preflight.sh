#!/bin/zsh

# Read-only runtime gate for the Network Extension lab.
# It does not install, save, enable, or remove any Network Extension setting.

set -u

script_dir="${0:A:h}"
lab_root="${script_dir:h}"
error_count=0
warning_count=0

pass() {
    print "PASS $1"
}

warn() {
    warning_count=$((warning_count + 1))
    print "WARN $1"
}

block() {
    error_count=$((error_count + 1))
    print "BLOCK $1"
}

print "ByteTrace Network Extension Lab preflight"
print "mode: read-only"
print "root: ${lab_root}"

if command -v xcodegen >/dev/null 2>&1; then
    pass "xcodegen is available"
else
    block "xcodegen is not available"
fi

if command -v xcodebuild >/dev/null 2>&1; then
    xcode_version="$(xcodebuild -version 2>/dev/null | tr '\n' ' ')"
    pass "xcodebuild is available (${xcode_version})"
else
    block "xcodebuild is not available"
fi

if [[ -f "${lab_root}/project.yml" ]]; then
    pass "XcodeGen project spec exists"
else
    block "missing ${lab_root}/project.yml"
fi

if [[ -f "${lab_root}/ByteTraceNetworkExtensionLab.xcodeproj/project.pbxproj" ]]; then
    pass "generated Xcode project exists"
else
    block "generated Xcode project is missing; run xcodegen first"
fi

for entitlement_file in \
    "${lab_root}/Host/Host.entitlements" \
    "${lab_root}/FilterProvider/FilterProvider.entitlements"; do
    if [[ ! -f "${entitlement_file}" ]]; then
        block "missing entitlement file: ${entitlement_file}"
    elif plutil -lint "${entitlement_file}" >/dev/null 2>&1; then
        pass "valid entitlement plist: ${entitlement_file:t}"
    else
        block "invalid entitlement plist: ${entitlement_file}"
    fi
done

identity_output="$(security find-identity -v -p codesigning 2>&1 || true)"
identity_count="$(print -r -- "${identity_output}" | awk '/valid identities found/{print $1; exit}')"
if [[ -z "${identity_count}" ]]; then
    block "unable to inspect code-signing identities"
elif (( identity_count > 0 )); then
    pass "${identity_count} valid code-signing identity(ies) found"
else
    block "no valid code-signing identity found"
fi

profile_dir="${HOME}/Library/MobileDevice/Provisioning Profiles"
if [[ -d "${profile_dir}" ]]; then
    profile_count="$(find "${profile_dir}" -maxdepth 1 -type f -name '*.mobileprovision' -print 2>/dev/null | wc -l | tr -d '[:space:]')"
else
    profile_count=0
fi

if (( profile_count > 0 )); then
    pass "${profile_count} provisioning profile file(s) found"
else
    warn "no local provisioning profile found; Xcode may create or download one later"
fi

product_path="${1:-}"
if [[ -n "${product_path}" ]]; then
    if [[ ! -e "${product_path}" ]]; then
        block "product path does not exist: ${product_path}"
    else
        signature_details="$(codesign -dvv "${product_path}" 2>&1 || true)"
        if print -r -- "${signature_details}" | grep -q 'Signature=adhoc'; then
            block "product is ad-hoc signed; Network Extension runtime needs a developer-signed product"
        elif print -r -- "${signature_details}" | grep -q 'Authority='; then
            pass "product has a developer signature: ${product_path}"
        else
            block "product is not developer signed: ${product_path}"
        fi
    fi
else
    warn "no built product supplied; pass the app path to inspect its signature"
fi

print "summary: ${error_count} blocking issue(s), ${warning_count} warning(s)"

if (( error_count > 0 )); then
    print "result: BLOCKED for runtime installation"
    exit 1
fi

print "result: READY for signed runtime validation"
