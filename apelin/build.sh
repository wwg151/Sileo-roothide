#!/bin/sh
# Writes Sileo's distribution package for the selected bootstrap.
#
# The Swift app is compiled by GitHub Actions (.github/workflows/build.yml),
# because this device has no Xcode and cannot build it. This script takes the
# package that workflow wrote, gives it the distribution identity below and
# writes the one .deb Apelin installs into APELIN_PACKAGE_DIR. The payload is
# never modified, so the app keeps the signature and entitlements CI gave it.
#
# Input, first that exists:
#   $SILEO_INPUT_DEB                    an explicit .deb path
#   dl/<anything>_<architecture>.deb   newest matching CI package by mtime
# Rootless requires a real iphoneos-arm64 build with /var/jb payload;
# this script does not convert roothide binaries into rootless binaries.
# Keep the payload in step with the version: layout/version and the app
# target's MARKETING_VERSION in Sileo.xcodeproj are bumped together.
set -eu

: "${APELIN_PACKAGE_DIR:?run this through apelin_project_build}"
: "${APELIN_PROJECT_ROOT:?}" "${APELIN_BOOTSTRAP:?}" "${APELIN_ARCHITECTURE:?}"
: "${APELIN_BUILD_ID:?}" "${TMPDIR:?}"
: "${APELIN_PREFIX?}" # set, and empty on roothide
: "${APELIN_CONFIGURATION:?}"

stage="$(mktemp -d "${TMPDIR:?}stage.XXXXXX")"
trap 'rm -rf -- "${stage:?}"' EXIT

PACKAGE_ID="org.coolstar.sileo"
PACKAGE_NAME="Sileo"
PACKAGE_AUTHOR="wwg151 <wwg151@users.noreply.github.com>"
PACKAGE_MAINTAINER="wwg151 <wwg151@users.noreply.github.com>"
PACKAGE_DESCRIPTION="A modern APT package manager frontend"
PACKAGE_VERSION="$(tr -d '[:space:]' < "${APELIN_PROJECT_ROOT:?}/layout/version")"
if [ -z "${PACKAGE_VERSION}" ]; then
    echo "error: layout/version holds no version" >&2
    exit 1
fi

case "${APELIN_BOOTSTRAP}" in
    roothide)
        expected_arch=iphoneos-arm64e
        expected_prefix=
        ;;
    rootless)
        expected_arch=iphoneos-arm64
        expected_prefix=/var/jb
        ;;
    *)
        echo "error: unsupported bootstrap '${APELIN_BOOTSTRAP}'" >&2
        exit 1
        ;;
esac
if [ "${APELIN_ARCHITECTURE}" != "${expected_arch}" ] ||
   [ "${APELIN_PREFIX}" != "${expected_prefix}" ]; then
    echo "error: ${APELIN_BOOTSTRAP} requires architecture ${expected_arch} and prefix '${expected_prefix}'" >&2
    exit 1
fi

input="${SILEO_INPUT_DEB:-}"
if [ -z "${input}" ]; then
    for candidate in "${APELIN_PROJECT_ROOT:?}"/dl/*_"${APELIN_ARCHITECTURE}".deb; do
        if [ -f "${candidate}" ]; then
            if [ -z "${input}" ] || [ "${candidate}" -nt "${input}" ]; then
                input="${candidate}"
            fi
        fi
    done
fi
if [ -z "${input}" ] || [ ! -f "${input}" ]; then
    echo "error: no ${APELIN_ARCHITECTURE} package to package from." >&2
    echo "       Download the ${APELIN_BOOTSTRAP} build from the repository's" >&2
    echo "       GitHub Actions release into dl/ (or set SILEO_INPUT_DEB)." >&2
    exit 1
fi

input_arch="$(dpkg-deb -f "${input}" Architecture)"
if [ "${input_arch}" != "${APELIN_ARCHITECTURE}" ]; then
    echo "error: ${input} is ${input_arch}, not ${APELIN_ARCHITECTURE}" >&2
    exit 1
fi
echo "packaging ${input} ($(dpkg-deb -f "${input}" Package) $(dpkg-deb -f "${input}" Version))"

dpkg-deb -x "${input}" "${stage}"
dpkg-deb -e "${input}" "${stage}/DEBIAN"
control="${stage}/DEBIAN/control"
if [ ! -f "${control}" ]; then
    echo "error: ${input} carries no DEBIAN/control" >&2
    exit 1
fi

# The identity fields are this project's; everything else (Depends, Section,
# Icon, SileoDepiction, maintainer scripts) is kept exactly as CI built it.
kept="$(grep -v -E '^(Package|Name|Version|Architecture|Author|Maintainer|Description):' "${control}" || true)"
{
    printf 'Package: %s\n' "${PACKAGE_ID}"
    printf 'Name: %s\n' "${PACKAGE_NAME}"
    printf 'Version: %s\n' "${PACKAGE_VERSION}"
    printf 'Architecture: %s\n' "${APELIN_ARCHITECTURE}"
    printf 'Author: %s\n' "${PACKAGE_AUTHOR}"
    printf 'Maintainer: %s\n' "${PACKAGE_MAINTAINER}"
    printf 'Description: %s\n' "${PACKAGE_DESCRIPTION}"
    if [ -n "${kept}" ]; then
        printf '%s\n' "${kept}"
    fi
} > "${stage}/DEBIAN/control.new"
mv -f "${stage}/DEBIAN/control.new" "${control}"

chmod 0755 "${stage}/DEBIAN"
chmod 0644 "${control}"
for name in preinst postinst prerm postrm config; do
    if [ -f "${stage}/DEBIAN/${name}" ]; then
        chmod 0755 "${stage}/DEBIAN/${name}"
    fi
done

app="${stage}${APELIN_PREFIX}/Applications/Sileo.app"
if [ ! -d "${app}" ]; then
    echo "error: ${input} has no ${APELIN_PREFIX}/Applications/Sileo.app" >&2
    exit 1
fi

output="${APELIN_PACKAGE_DIR:?}/${PACKAGE_ID}_${PACKAGE_VERSION}_${APELIN_ARCHITECTURE}.deb"
dpkg-deb -Zxz --root-owner-group -b "${stage}" "${output}"

echo "configuration: ${APELIN_CONFIGURATION}"
echo "wrote ${output}"
dpkg-deb -f "${output}" Package Version Architecture Name
