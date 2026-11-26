#!/bin/bash
set -euo pipefail

FILE="$1"
BASE="${FILE%.gz.gpg}"

gpg --decrypt --output "${BASE}.gz" "$FILE"
gzip -t "${BASE}.gz"
gunzip -c "${BASE}.gz" > "${BASE}"
rm "${BASE}.gz"

tail -n 1 "${BASE}" | grep -q '^-- Dump completed' || { echo "No completion marker, the dump may be truncated" >&2; exit 1; }

echo "Tables in backup:"
grep '^CREATE TABLE' "${BASE}" | sed 's/^CREATE TABLE `\([^`]*\)`.*/  \1/'
