#!/bin/sh
# Cisco IOS config backup over IPv6 SCP
set -u

BACKUP_ROOT="/root/cisco-backups"
CRED_FILE="/root/.cisco-backup-creds"
KNOWN_HOSTS="/root/.ssh/known_hosts_cisco"
USERNAME="backup"
RETAIN_DAYS=90
TAG="cisco-backup"

STAMP="$(date '+%Y-%m-%d_%H%M')"
DEST="$BACKUP_ROOT/$STAMP"
LATEST="$BACKUP_ROOT/latest"

log() {
    echo "$(date '+%H:%M:%S') $*"
    logger -t "$TAG" "$*" 2>/dev/null || true
}

if [ ! -r "$CRED_FILE" ]; then
    log "FATAL: cannot read $CRED_FILE"
    exit 1
fi

. "$CRED_FILE"

mkdir -p "$DEST" "$LATEST" "$(dirname "$KNOWN_HOSTS")"

fetch() {
    sshpass -p "$PASSWORD" scp -O -6 -q \
        -o KexAlgorithms=+diffie-hellman-group14-sha1 \
        -o HostKeyAlgorithms=+ssh-rsa \
        -o PubkeyAcceptedAlgorithms=+ssh-rsa \
        -o Ciphers=+aes128-cbc,aes192-cbc,aes256-cbc \
        -o MACs=+hmac-sha1 \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile="$KNOWN_HOSTS" \
        -o ConnectTimeout=15 \
        "$1" "$2" 2>/dev/null
}

valid() {
    [ -s "$1" ] && grep -q '^end' "$1" && grep -q '^hostname' "$1"
}

normalize() {
    grep -vE '^(Current configuration|! Last configuration change|! NVRAM config last updated|ntp clock-period)' "$1"
}

OK=0
FAIL=0
DRIFT=""

while read -r NAME ADDR; do
    [ -z "$NAME" ] && continue

    RUN="$DEST/$NAME-running.cfg"
    START="$DEST/$NAME-startup.cfg"

    printf '%-10s ' "$NAME"

    if ! fetch "$USERNAME@[$ADDR]:running-config" "$RUN"; then
        echo "FAILED (transfer)"
        log "FAILED $NAME ($ADDR) - transfer error"
        rm -f "$RUN"
        FAIL=$((FAIL + 1))
        continue
    fi

    if ! valid "$RUN"; then
        echo "FAILED (truncated/invalid)"
        log "FAILED $NAME ($ADDR) - invalid content"
        rm -f "$RUN"
        FAIL=$((FAIL + 1))
        continue
    fi

    LINES=$(wc -l < "$RUN")
    CHANGED=""

    if [ -f "$LATEST/$NAME-running.cfg" ]; then
        if ! normalize "$RUN" | diff -q - <(normalize "$LATEST/$NAME-running.cfg") >/dev/null 2>&1; then
            CHANGED=" [CHANGED]"
            log "CHANGED $NAME - config differs from previous backup"
        fi
    fi

    if fetch "$USERNAME@[$ADDR]:startup-config" "$START" && valid "$START"; then
        if ! normalize "$RUN" | diff -q - <(normalize "$START") >/dev/null 2>&1; then
            DRIFT="$DRIFT $NAME"
        fi
    else
        rm -f "$START"
    fi

    cp "$RUN" "$LATEST/$NAME-running.cfg"

    echo "OK (${LINES} lines)${CHANGED}"
    OK=$((OK + 1))
done <<'DEVLIST'
DC1-R1 2001:db8:1:ffff::1
DC1-R2 2001:db8:1:ffff::2
DC2-R1 2001:db8:1:ffff::3
DC2-R2 2001:db8:1:ffff::4
vIOS-7 2001:db8:1:ffff::7
DEVLIST

echo "---"
log "Backup complete: $OK ok, $FAIL failed -> $DEST"

if [ -n "$DRIFT" ]; then
    log "UNSAVED CHANGES (running != startup):$DRIFT"
    echo "WARNING: unsaved config on:$DRIFT"
fi

find "$BACKUP_ROOT" -maxdepth 1 -type d -name '20*' -mtime "+$RETAIN_DAYS" -exec rm -rf {} + 2>/dev/null

rmdir "$DEST" 2>/dev/null

exit "$FAIL"