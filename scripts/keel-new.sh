#!/bin/zsh
##===----------------------------------------------------------------------===##
## keel-new.sh — scaffold a new Keel app from Templates/SampleApp.
##
## Usage: scripts/keel-new.sh MyApp [destination-dir]
##
## Deliberately a copy-and-rename script, nothing more (the plan defers a real
## generator): it copies the template, rewrites the sample names, and prints the
## follow-ups the README describes.
##===----------------------------------------------------------------------===##
set -euo pipefail

fatal() { printf -- "error: %s\n" "$*" >&2; exit 1; }

NAME="${1:-}"
[ -n "${NAME}" ] || fatal "usage: keel-new.sh MyApp [destination-dir]"
case "${NAME}" in
    (*[!A-Za-z0-9]*) fatal "app name must be alphanumeric (got \"${NAME}\")" ;;
esac

SCRIPT_DIR="${0:a:h}"
TEMPLATE="${SCRIPT_DIR:h}/Templates/SampleApp"
LOWER="${NAME:l}"
DEST="${2:-./${NAME}}"

[ -d "${TEMPLATE}" ] || fatal "template not found at ${TEMPLATE}"
[ ! -e "${DEST}" ] || fatal "${DEST} already exists"

cp -R "${TEMPLATE}" "${DEST}"

# Rename in file contents…
find "${DEST}" -type f \( -name '*.swift' -o -name '*.ts' -o -name '*.json' -o -name '*.md' \) \
    -exec perl -pi -e "s/SampleApp/${NAME}/g; s/sampleapp/${LOWER}/g; s/sample-app/${LOWER}/g" {} +

# …and in file names. (The loop variable must not be "path": in zsh that is the
# array tied to PATH, and assigning it un-finds every command that follows.)
find "${DEST}" -depth -name '*sample-app*' | while read -r entry; do
    mv "${entry}" "${entry//sample-app/${LOWER}}"
done
find "${DEST}" -depth -name '*SampleApp*' | while read -r entry; do
    mv "${entry}" "${entry//SampleApp/${NAME}}"
done

cat <<DONE
Created ${DEST} from the Keel template.

Next:
  1. cd ${DEST}/backend && npm install && npx cdk deploy
  2. Set baseURL in App/${NAME}.swift to the ApiBaseUrl output.
  3. Follow ${DEST}/README.md for the Xcode project wiring.
DONE
