#!/bin/bash
# Optional: put the deployment server behind HTTPS with CLIENT-CERTIFICATE authentication (nginx).
#
# The deployment server keeps listening on 127.0.0.1:8080 only. nginx terminates TLS on 443 and lets a browser
# through only when it presents a client certificate issued by YOUR CA. The page itself has no login, so
# never expose 8080 or put nginx in front without client certificates (or another authentication).
#
# Usage (as root on the deployment server, after the CA has signed this server's certificate):
#   enable-https-client-cert.sh --name deploy01.corp.local --cert server.crt --ca ca.crt [--key server.key]
#   --name   the FQDN users type in the browser (must be in the certificate's subjectAltName)
#   --cert   this server's certificate (PEM), issued by your CA
#   --ca     the CA certificate (PEM) that issued the CLIENT certificates (usually the same CA)
#   --key    this server's private key (default /etc/nginx/tls/server.key, created by --make-csr)
#   --make-csr  only create the key + certificate request (/etc/nginx/tls/server.{key,csr}) and print the CSR
# Needs the nginx package (Rocky 9 AppStream). Idempotent.
set -euo pipefail
NAME=""; CERT=""; CA=""; KEY=/etc/nginx/tls/server.key; MAKE_CSR=0
while [ $# -gt 0 ]; do case "$1" in
  --name) NAME=$2; shift 2;; --cert) CERT=$2; shift 2;; --ca) CA=$2; shift 2;; --key) KEY=$2; shift 2;;
  --make-csr) MAKE_CSR=1; shift;; *) echo "unknown argument: $1"; exit 2;; esac; done
[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }
rpm -q nginx >/dev/null 2>&1 || dnf -y install nginx
T=/etc/nginx/tls; install -d -m 750 -o root -g nginx $T

if [ $MAKE_CSR = 1 ]; then
  [ -n "$NAME" ] || { echo "--name is required"; exit 2; }
  # The private key is created here and never leaves this server.
  [ -f $T/server.key ] || openssl req -new -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
       -keyout $T/server.key -subj "/CN=$NAME" -addext "subjectAltName=DNS:$NAME" -out $T/server.csr 2>/dev/null
  chgrp nginx $T/server.key; chmod 640 $T/server.key
  cat $T/server.csr; exit 0
fi
[ -n "$NAME" ] && [ -f "$CERT" ] && [ -f "$CA" ] && [ -f "$KEY" ] || { echo "need --name, --cert, --ca (and the key at $KEY)"; exit 2; }
openssl x509 -in "$CERT" -noout -pubkey | cmp -s - <(openssl pkey -in "$KEY" -pubout) || { echo "certificate does not match $KEY"; exit 1; }
openssl x509 -in "$CERT" -noout -checkhost "$NAME" | grep -q "does match" || { echo "certificate is not valid for $NAME"; exit 1; }
install -m 644 -o root -g nginx "$CERT" $T/server.crt
install -m 644 -o root -g nginx "$CA"   $T/client-ca.crt
[ "$KEY" = $T/server.key ] || { install -m 640 -o root -g nginx "$KEY" $T/server.key; }

cat > /etc/nginx/conf.d/autodeploy-https.conf <<N
# AutoDeploy deployment server: TLS + client-certificate authentication in front of 127.0.0.1:8080.
log_format autodeploy_tls '\$remote_addr [\$time_local] "\$request" \$status \$body_bytes_sent client="\$ssl_client_s_dn" verify=\$ssl_client_verify';
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;
    server_name $NAME;

    ssl_certificate        $T/server.crt;
    ssl_certificate_key    $T/server.key;
    ssl_protocols          TLSv1.2 TLSv1.3;
    ssl_client_certificate $T/client-ca.crt;
    ssl_verify_client      on;
    ssl_verify_depth       1;

    access_log /var/log/nginx/autodeploy-https.log autodeploy_tls;
    client_max_body_size 16m;
    add_header Strict-Transport-Security "max-age=31536000" always;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_set_header   Host 127.0.0.1:8080;      # the server's HttpListener answers only to its own prefix
        proxy_set_header   X-Client-Cert-DN \$ssl_client_s_dn;
        proxy_http_version 1.1;
        proxy_buffering    off;                       # live run logs
        proxy_read_timeout 600s;
    }
}
N
restorecon -R /etc/nginx
setsebool -P httpd_can_network_connect on            # SELinux: nginx -> 127.0.0.1:8080
nginx -t
systemctl enable --now nginx; systemctl reload nginx
firewall-cmd -q --permanent --add-service=https && firewall-cmd -q --reload
echo "HTTPS on https://$NAME/ - without a client certificate the answer must be HTTP 400:"
curl -sk -o /dev/null -w "  no client cert -> HTTP %{http_code}\n" --resolve "$NAME:443:127.0.0.1" "https://$NAME/"
