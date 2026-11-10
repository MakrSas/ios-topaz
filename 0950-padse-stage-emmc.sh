#!/bin/bash
# Register the Pad SE eMMC root device (bsd/dev/sweet_emmc.c, added by
# 0950-padse-emmc-root-device.patch) in the XNU build.
# dxb runs patches/*.sh from the XNU source root before applying *.patch, so the
# line is appended at the end of bsd/conf/files: no other patch has context there.
set -euo pipefail

[[ "${MACHINE_CONFIG:-}" == SWEET ]] || exit 0
[[ -f bsd/conf/files ]] || exit 1

if ! grep -q 'sweet_emmc\.c' bsd/conf/files; then
    printf 'bsd/dev/sweet_emmc.c\t\t\tstandard\n' >> bsd/conf/files
fi
