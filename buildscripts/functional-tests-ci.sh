#!/usr/bin/env bash
# Run the existing functional gate against an isolated HTTPS S3 server.
# No requests or test objects are sent to the public play.min.io service.
set -euo pipefail

fixture=$(mktemp -d)
container="mc-functional-${RANDOM}-${RANDOM}"
ca_name="mc-functional-${RANDOM}-${RANDOM}.crt"
cleanup() {
    docker rm -f "$container" >/dev/null 2>&1 || true
    sudo rm -f "/usr/local/share/ca-certificates/$ca_name"
    sudo update-ca-certificates >/dev/null 2>&1 || true
    rm -rf "$fixture"
}
trap cleanup EXIT
mkdir -p "$fixture/certs"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -keyout "$fixture/certs/private.key" -out "$fixture/certs/public.crt" \
    -subj '/CN=localhost' -addext 'subjectAltName=DNS:localhost,IP:127.0.0.1' \
    >/dev/null 2>&1
sudo cp "$fixture/certs/public.crt" "/usr/local/share/ca-certificates/$ca_name"
sudo update-ca-certificates >/dev/null

export SERVER_ENDPOINT=127.0.0.1:9000
export ACCESS_KEY=mc-functional-user
export SECRET_KEY
SECRET_KEY=$(openssl rand -hex 24)
export ENABLE_HTTPS=1

docker run -d --name "$container" -p 127.0.0.1:9000:9000 \
    -e "MINIO_ROOT_USER=$ACCESS_KEY" -e "MINIO_ROOT_PASSWORD=$SECRET_KEY" \
    -v "$fixture/certs:/certs:ro" \
    quay.io/minio/minio:RELEASE.2025-04-22T22-12-26Z \
    server /data --certs-dir /certs --address :9000 >/dev/null
for attempt in $(seq 1 60); do
    if curl --fail --silent --cacert "$fixture/certs/public.crt" \
        "https://$SERVER_ENDPOINT/minio/health/ready" >/dev/null; then
        make verify
        exit 0
    fi
    sleep 1
done
docker logs "$container"
echo 'The isolated HTTPS S3 fixture did not become ready' >&2
exit 1
