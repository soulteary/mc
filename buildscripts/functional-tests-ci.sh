#!/usr/bin/env bash
# Run the existing functional gate against an isolated HTTPS S3 server.
# No requests or test objects are sent to the public play.min.io service.
set -euo pipefail

fixture=$(mktemp -d)
server_pid=
cleanup() {
    if [ -n "$server_pid" ]; then
        kill "$server_pid" >/dev/null 2>&1 || true
        wait "$server_pid" 2>/dev/null || true
    fi
    rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$fixture/certs/private.key" -out "$fixture/certs/public.crt" \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    >/dev/null 2>&1

export SERVER_ENDPOINT=127.0.0.1:9000
export ACCESS_KEY=mc-functional-user
export SECRET_KEY
SECRET_KEY=$(openssl rand -hex 24)
export ENABLE_HTTPS=1

# Build the exact server revision already pinned by this client. Keep its
# module graph separate so fixture dependencies cannot modify the client.
server_source=$(go list -m -f '{{.Dir}}' github.com/soulteary/otterio)
mkdir -p "$fixture/server" "$fixture/data"
cp -a "$server_source/." "$fixture/server/"
chmod -R u+w "$fixture/server"
(cd "$fixture/server" && go build -mod=mod -o "$fixture/otterio" .)
OTTERIO_ACCESS_KEY="$ACCESS_KEY" OTTERIO_SECRET_KEY="$SECRET_KEY" \
OTTERIO_ROOT_USER="$ACCESS_KEY" OTTERIO_ROOT_PASSWORD="$SECRET_KEY" \
OTTERIO_BROWSER=off "$fixture/otterio" --config-dir "$fixture/config" \
    --certs-dir "$fixture/certs" server --address "$SERVER_ENDPOINT" "$fixture/data" \
    >"$fixture/server.log" 2>&1 &
server_pid=$!
export SSL_CERT_FILE="$fixture/certs/public.crt"
for attempt in $(seq 1 60); do
    if curl --fail --silent --cacert "$fixture/certs/public.crt" \
        "https://$SERVER_ENDPOINT/otterio/health/ready" >/dev/null; then
        make verify
        exit 0
    fi
    sleep 1
done
cat "$fixture/server.log"
echo 'The isolated HTTPS S3 fixture did not become ready' >&2
exit 1
