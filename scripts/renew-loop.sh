#!/bin/sh
set -eu
# Run the same certificate operation as the CLI, including its distributed lock
# and nginx -t gate. Load scripts from the active release on every attempt.
trap 'exit 0' INT TERM
sleep 30 &
wait "$!"
while :; do
    if sh /gateway/current/automation/scripts/certificates.sh renew; then
        date +%s > /tmp/renewal-success
        rm -f /tmp/renewal-failed
        printf '%s Certificate renewal check succeeded; next check in 6 hours.\n' "$(date -u)"
        delay=21600
    else
        touch /tmp/renewal-failed
        printf '%s Certificate renewal or reload failed; retry in 5 minutes.\n' "$(date -u)" >&2
        delay=300
    fi
    sleep "$delay" &
    wait "$!"
done
