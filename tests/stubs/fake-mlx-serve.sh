#!/bin/sh
# fake-mlx-serve.sh — test stub for mlx-serve 26.10.1 (#1).
# --version prints "mlx-serve $MSS_STUB_MLX_VERSION" (default 26.10.1), then
# component lines like the real multi-line report, and exits
# MSS_STUB_MLX_RC (default 0); while the file ${MSS_STUB_MLX_HANG:-/tmp/mss-stub-mlx-hang}
# exists it hangs instead. Serving, it logs "<pid> <argv>" to $MSS_STUB_ARGV
# (default /tmp/mss-stub-mlx-argv) and answers every request on --port with 200
# and the body in /tmp/mss-stub-mlx-models (default one ready model), so
# /health is 200 and /v1/models reports "state":"ready". TERM stops it at once.

set -u

if [ "${1:-}" = --version ]; then
    while [ -e "${MSS_STUB_MLX_HANG:-/tmp/mss-stub-mlx-hang}" ]; do sleep 1; done
    echo "mlx-serve ${MSS_STUB_MLX_VERSION:-26.10.1}"
    printf 'mlx 0.0.0-stub\nmlx-c 0.0.0-stub\nggml unknown\nllama.cpp unknown\ngguf 3\nds4 unknown\n'
    exit "${MSS_STUB_MLX_RC:-0}"
fi

ARGV_FILE=${MSS_STUB_ARGV:-/tmp/mss-stub-mlx-argv}
printf '%s %s\n' "$$" "$*" >> "$ARGV_FILE"
HOST=127.0.0.1; PORT=11234; _prev=""
for _a in "$@"; do
    case $_prev in --host) HOST=$_a ;; --port) PORT=$_a ;; esac
    _prev=$_a
done

_response() {
    _body=$(cat /tmp/mss-stub-mlx-models 2>/dev/null) \
        || _body='{"object":"list","data":[{"id":"stub","loaded":true,"state":"ready"}]}'
    [ -n "$_body" ] || _body='{"object":"list","data":[{"id":"stub","loaded":true,"state":"ready"}]}'
    printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#_body}" "$_body"
}

_nc=""
_term() {
    if [ -n "$_nc" ]; then kill "$_nc" 2>/dev/null; wait "$_nc" 2>/dev/null; fi
    exit 0
}
trap _term TERM

while :; do
    _response | nc -l "$HOST" "$PORT" >/dev/null 2>&1 &
    _nc=$!
    wait "$_nc" || sleep 1
done
