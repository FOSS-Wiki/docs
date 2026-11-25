#!/bin/bash
set -euo pipefail
shopt -s nullglob

# no spaces, all lowercase
# e.g. fosswiki
WIKI_NAME=""
# the actual name
# e.g. FOSS Wiki
WIKI_TITLE=""
# e.g. foss.wiki
WIKI_DOMAIN=""
# the SPDX identifier
# e.g CC-BY-SA-4.0
LICENSE=""
# e.g. https://creativecommons.org/licenses/by-sa/4.0
LICENSE_URL=""
# do not include the trailing /
# e.g. https://foss.wiki
MW_URL=""
# include the leading /
# e.g. /api.php
API_PATH=""
# e.g. admin@example.com
ADMIN_EMAIL=""
# wherever you will serve the files from
MIRROR_DIR=/opt/mirror
# number of copies of archives to keep
KEEP_COPIES=2

# Avoid changing these
DATE=$(date +%Y-%m-%d)
TEMP_DIR="/var/tmp/${DATE}_archive"
TEXTDUMP_DIR="${TEMP_DIR}/${DATE}_${WIKI_NAME}-textdump"
FULLDUMP_DIR="${TEMP_DIR}/${DATE}_${WIKI_NAME}-fulldump"
IDENTIFIER="${WIKI_NAME}_${DATE}"
IA_FAILED=0

# Keep the newest <KEEP_COPIES> of each type in the mirror dir
prune() {
  local pattern="$1"

  [[ "$KEEP_COPIES" =~ ^[0-9]+$ ]] || {
    echo "prune: invalid KEEP_COPIES: '$KEEP_COPIES'" >&2
    return 1
  }

  find "$MIRROR_DIR" -mindepth 1 -maxdepth 1 -name "$pattern" -printf '%T@ %p\0' \
    | sort -z -rn | tail -z -n +"$((KEEP_COPIES + 1))" | cut -z -d' ' -f2- | xargs -0 -r rm -rf --
}

cleanup() {
  local rc=$?
  set +e +o pipefail
  cd /
  rm -rf -- "$TEMP_DIR"
  echo "=== Pruning old archives ==="
  prune "*_${WIKI_NAME}-textdump.tar"
  prune "*_${WIKI_NAME}-fulldump.tar"
  prune "*_${WIKI_NAME}_zimdump.zim"
  exit "$rc"
}
trap cleanup EXIT # runs every time incase of error

# Compress every XML file in a dump dir
compress_xml() {
  local dir="$1" xmlfile
  for xmlfile in "$dir"/*.xml; do
    if [ ! -f "${xmlfile}.zst" ]; then
      echo "Compressing $xmlfile ..."
      zstd -q --rm -T0 -19 --long=27 "$xmlfile"
    fi
  done
}

# Upload text dump to Internet Archive using ia CLI tool
upload_to_ia() {
  cd "$TEXTDUMP_DIR" || return 1

  logos=("${WIKI_DOMAIN}"-*-logo.png)
  if [ "${#logos[@]}" -gt 0 ]; then
    cp -- "${logos[0]}" "${WIKI_NAME}-logo.png" || return 1
  else
    echo "Warning: no logo file found, continuing without it"
  fi

  FILES=()
  for f in *.zst siteinfo.json SpecialVersion.html "${WIKI_NAME}-logo.png" index.html; do
    if [ -e "$f" ]; then
      FILES+=("$f")
    fi
  done

  if [ "${#FILES[@]}" -eq 0 ]; then
    echo "No files found to upload in $TEXTDUMP_DIR"
    return 1
  fi

  echo "=== Files to upload ==="
  printf '  %s\n' "${FILES[@]}"

  echo "=== Uploading to Internet Archive as ${IDENTIFIER} ==="
  DESCRIPTION="<a href=\"${MW_URL}\" rel=\"ugc nofollow\">${WIKI_TITLE}</a> text content dumped with <a href=\"https://github.com/saveweb/wikiteam3\" rel=\"ugc nofollow\">wikiteam3</a> tools."
  ia upload "$IDENTIFIER" "${FILES[@]}" \
    --metadata="mediatype:web" \
    --metadata="collection:opensource;wikicollections;${WIKI_NAME}" \
    --metadata="title:${WIKI_TITLE}" \
    --metadata="description:${DESCRIPTION}" \
    --metadata="subject:wiki;MediaWiki;wikiteam3;${WIKI_NAME};${WIKI_DOMAIN}" \
    --metadata="creator:${WIKI_TITLE}" \
    --metadata="originalurl:${MW_URL}" \
    --metadata="language:en" \
    --metadata="date:${DATE}" \
    --metadata="rights:${LICENSE}" \
    --metadata="licenseurl:${LICENSE_URL}" \
    --retries 5 || return 1

  echo "URL: https://archive.org/details/${IDENTIFIER}"
}

mkdir -p "$TEMP_DIR"

# Generate XML (one with and one without images) dumps using wikiteam3dumpgenerator
wikiteam3dumpgenerator --xmlrevisions --xml --delay 1 --path "$TEXTDUMP_DIR" --api "${MW_URL}${API_PATH}" --force
sleep 5
wikiteam3dumpgenerator --xmlrevisions --xml --images --delay 1 --path "$FULLDUMP_DIR" --api "${MW_URL}${API_PATH}" --force
sleep 5

# Generate & process ZIM dump using mwoffliner
podman run --rm -v "$TEMP_DIR":/output:Z ghcr.io/openzim/mwoffliner mwoffliner --mwUrl="${MW_URL}" --adminEmail="${ADMIN_EMAIL}" --outputDirectory=/output --mwActionApiPath="${API_PATH}"
sleep 5
cp "$TEMP_DIR"/*.zim "$MIRROR_DIR/${DATE}_${WIKI_NAME}_zimdump.zim"

# Compress all the XML files
compress_xml "$TEXTDUMP_DIR"
compress_xml "$FULLDUMP_DIR"

upload_to_ia || {
  echo "WARNING: Internet Archive upload failed, continuing" >&2
  IA_FAILED=1
}
cd /

# Tar the dump dirs into /opt/mirror
for d in "$TEXTDUMP_DIR" "$FULLDUMP_DIR"; do
  echo "Bundling $(basename "$d") ..."
  tar -C "$TEMP_DIR" -cf "${MIRROR_DIR}/$(basename "$d").tar" "$(basename "$d")"
  rm -rf -- "$d"
done

echo "=== Done ==="

if [ "$IA_FAILED" -ne 0 ]; then
  exit 1
fi
