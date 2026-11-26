#!/bin/bash
set -euo pipefail

# The name of your database for mediawiki
# e.g. "mediawiki"
DB_NAME=""
# The fingerprint of the key, get it with:
# sudo -H -u db-backup gpg --list-keys --with-fingerprint
RECIPIENT=""
# rclone config section header
# e.g. "dbbackup-s3"
RCLONE_HEADER=""
# The name of your S3 bucket
# e.g. "db-backup"
BUCKET_NAME=""

# Customise the filename for backups in the bucket
DATE=$(date +%Y-%m-%d)
FILENAME="${DATE}-dbbackup.sql.gz.gpg"

# Only change these if you created the files rootfully, avoid changing otherwise
MYSQL_CNF="/etc/db-backup/my.cnf"
RCLONE_CONF="/etc/db-backup/rclone.conf"

umask 077

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
DUMP_FILE="${TMP_DIR}/${FILENAME}"

mysqldump --defaults-extra-file="$MYSQL_CNF" --single-transaction --quick "$DB_NAME" \
  | gzip \
  | gpg --batch --trust-model always --encrypt --recipient "$RECIPIENT" --output "$DUMP_FILE"

# Checks the backup was successful
[ -s "$DUMP_FILE" ] || { echo "Encrypted backup is empty, aborting" >&2; exit 1; }

rclone --config "$RCLONE_CONF" copyto "$DUMP_FILE" "${RCLONE_HEADER}:${BUCKET_NAME}/${FILENAME}"
