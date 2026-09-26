#!/bin/sh
# fake-ollama.sh — installed as /usr/local/bin/ollama in CI phase B only.
# Ignores its arguments ("serve") and answers every request on 11434 with a
# fixed /api/version body, so the real 1.3.0 Ollama install flow can run.

BODY='{"version":"0.0.0-stub"}'
while :; do
    printf 'HTTP/1.0 200 OK\r\nContent-Type: application/json\r\nContent-Length: %s\r\n\r\n%s' "${#BODY}" "$BODY" \
        | nc -l 11434 >/dev/null 2>&1 || sleep 1
done
