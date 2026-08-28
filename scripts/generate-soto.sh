#!/bin/zsh
##===----------------------------------------------------------------------===##
## generate-soto.sh
##
## Maintainer-run script that generates a minimal DynamoDB client from the Soto
## Code Generator, with only the operations Keel uses (docs/adr/0006-codegen-soto.md).
## NOT part of the build. Generated files are committed under
## server/Sources/Soto/DynamoDB and build with relaxed SwiftSettings.
##===----------------------------------------------------------------------===##
set -euo pipefail
log() { printf -- "** %s\n" "$*" >&2; }
fatal() { printf -- "** ERROR: %s\n" "$*" >&2; exit 1; }

SCRIPT_DIR="${0:a:h}"
PROJECT_ROOT="${SCRIPT_DIR:h}"
WORK_DIR="${PROJECT_ROOT}/.build/codegen-work"

command -v swift &>/dev/null || fatal "Swift toolchain not found"
command -v git &>/dev/null || fatal "git not found"

log "Setting up ${WORK_DIR}"
mkdir -p "${WORK_DIR}"

if [ -d "${WORK_DIR}/soto-codegenerator" ]; then
    git -C "${WORK_DIR}/soto-codegenerator" pull --quiet || true
else
    git clone --quiet --depth 1 --branch main \
        https://github.com/soto-project/soto-codegenerator.git \
        "${WORK_DIR}/soto-codegenerator"
fi

log "Building Soto Code Generator (release)..."
( cd "${WORK_DIR}/soto-codegenerator" && swift build -c release 2>&1 | tail -3 )

# Only the operations Keel performs. Adding one here means re-running this
# script and reviewing the diff it produces. SSM exists for exactly one call —
# the authorizer reading its shared secret at cold start — and describeEndpoints
# only because the generated client's endpoint-discovery plumbing calls it.
cat > "${WORK_DIR}/soto.config.json" << 'EOF'
{
    "services": {
        "dynamodb": {
            "operations": ["updateItem", "query", "getItem", "putItem", "describeEndpoints"]
        },
        "ssm": {
            "operations": ["getParameter"]
        }
    }
}
EOF

# SotoModelDownloader walks the aws/api-models-aws git tree through the GitHub
# API, and that recursive tree call 504s — the repo is too large for it. Fetch
# the two files it would have produced directly instead, pinned to the same
# model hash soto itself builds against.
MODELS="${WORK_DIR}/models"
mkdir -p "${MODELS}"
log "Downloading models..."
MODEL_HASH="$(curl -sfL https://raw.githubusercontent.com/soto-project/soto/main/.aws-model-hash | tr -d '[:space:]')"
[ -n "${MODEL_HASH}" ] || fatal "could not read soto's .aws-model-hash"
log "Model hash: ${MODEL_HASH}"
for service in dynamodb ssm; do
    SERVICE_PATH="$(
        curl -sfL "https://api.github.com/repos/aws/api-models-aws/contents/models/${service}/service?ref=${MODEL_HASH}" \
            | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["path"])'
    )"
    SERVICE_FILE="$(
        curl -sfL "https://api.github.com/repos/aws/api-models-aws/contents/${SERVICE_PATH}?ref=${MODEL_HASH}" \
            | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["path"])'
    )"
    log "Model file: ${SERVICE_FILE}"
    curl -sfL "https://raw.githubusercontent.com/aws/api-models-aws/${MODEL_HASH}/${SERVICE_FILE}" \
        -o "${MODELS}/${service}.json"
done
curl -sfL "https://raw.githubusercontent.com/aws/aws-sdk-go-v2/refs/heads/main/codegen/smithy-aws-go-codegen/src/main/resources/software/amazon/smithy/aws/go/codegen/endpoints.json" \
    -o "${MODELS}/endpoints.json"

CODEGEN="${WORK_DIR}/soto-codegenerator/.build/release/SotoCodeGenerator-tool"
[ -x "${CODEGEN}" ] || CODEGEN="${WORK_DIR}/soto-codegenerator/.build/release/SotoCodeGenerator"
for service in dynamodb:DynamoDB ssm:SSM; do
    lower="${service%%:*}"
    name="${service##*:}"
    GEN="${WORK_DIR}/generated/Soto${name}"
    mkdir -p "${GEN}"
    log "Generating Soto${name}..."
    "${CODEGEN}" \
        --output-folder "${GEN}" \
        --input-file "${MODELS}/${lower}.json" \
        --config "${WORK_DIR}/soto.config.json" \
        --endpoints "${MODELS}/endpoints.json" \
        --log-level info

    DEST="${PROJECT_ROOT}/server/Sources/Soto/${name}"
    if [ -d "${GEN}" ] && [ "$(ls -A "${GEN}" 2>/dev/null)" ]; then
        rm -rf "${DEST}"; mkdir -p "${DEST}"; cp -r "${GEN}/"* "${DEST}/"
        log "Soto${name} → ${DEST} ($(ls "${DEST}" | wc -l | tr -d ' ') files)"
    else
        fatal "no generated files for ${name}"
    fi
done
log "Done."
