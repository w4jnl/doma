#!/bin/sh
# Restore doma from a backup zip (Back up now on /admin/server) into an empty data directory:
# the database, secret.key and the photos land where the server expects them. Stop doma
# first, start it on the directory afterwards; the phones carry on with their keys.
#
#   scripts/restore.sh doma-backup-20261106-180000.zip /var/lib/doma
#
# With the container, the data directory is the volume mounted at /data; run the script on
# the host against the volume's path, or unzip the file into the volume from a helper image:
#   docker run --rm -v doma-data:/data -v "$PWD:/b" alpine sh -c 'unzip -q /b/doma-backup-X.zip -d /data'
set -eu
if [ $# -ne 2 ]; then
  echo "usage: scripts/restore.sh <backup.zip> <empty data directory>" >&2
  exit 2
fi
ZIP=$1
DIR=$2
[ -f "$ZIP" ] || { echo "restore: no such file: $ZIP" >&2; exit 1; }
unzip -l "$ZIP" | grep -q ' doma.db$' || { echo "restore: $ZIP holds no doma.db; is it a doma backup?" >&2; exit 1; }
mkdir -p "$DIR"
if [ -n "$(ls -A "$DIR")" ]; then
  echo "restore: $DIR is not empty; a restore goes onto an empty data directory" >&2
  exit 1
fi
unzip -q "$ZIP" -d "$DIR"
chmod 600 "$DIR/doma.db"
[ -f "$DIR/secret.key" ] && chmod 600 "$DIR/secret.key"
photos=$(find "$DIR/photos" -type f 2>/dev/null | wc -l | tr -d ' ')
echo "restore: $DIR has doma.db$([ -f "$DIR/secret.key" ] && printf ', secret.key'), $photos photos; start doma on it"
