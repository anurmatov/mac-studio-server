#!/bin/sh
# fake-server.sh — test stub for llama-server/ds4-server/ollama.
# Logs its argv to $MSS_STUB_ARGV (default /tmp/mss-stub-argv), proving what the
# wrapper exec'd, then serves trivial 200 responses on --port (default
# $MSS_STUB_PORT) until killed.
#
# On TERM it sleeps for the seconds in /tmp/mss-stub-term-delay (none: 0) before
# exiting, like a backend that takes a while to release a large model (#18).

set -u

ARGV_FILE=${MSS_STUB_ARGV:-/tmp/mss-stub-argv}
HOST=${MSS_STUB_HOST:-127.0.0.1}
PORT=${MSS_STUB_PORT:-}

printf '%s\n' "$*" >> "$ARGV_FILE"

# pick the --port the wrapper passed, if any
_prev=""
for _a in "$@"; do
    case $_prev in --host) HOST=$_a ;; --port) PORT=$_a ;; esac
    _prev=$_a
done
PORT=${PORT:-8080}

_response() {
    printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: 2\r\n\r\n{}'
}

# nc runs in the background and the shell waits for it, so the trap runs at once.
_nc=""
_term() {
    _delay=$(cat /tmp/mss-stub-term-delay 2>/dev/null)
    sleep "${_delay:-0}"
    # Wait for nc, so the port is free before launchd sees the job exit.
    if [ -n "$_nc" ]; then kill "$_nc" 2>/dev/null; wait "$_nc" 2>/dev/null; fi
    exit 0
}
trap _term TERM

while :; do
    _response | nc -l "$HOST" "$PORT" >/dev/null 2>&1 &
    _nc=$!
    wait "$_nc" || sleep 1
done
