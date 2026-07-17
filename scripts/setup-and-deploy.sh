#!/usr/bin/env bash
# Cloud Mail — create D1/KV, configure, deploy, wire Email Routing catch-all
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKER_DIR="$ROOT/mail-worker"
SECRETS_FILE="$ROOT/.local-secrets.env"
IDS_FILE="$ROOT/.deploy-ids.json"
TOML_FILE="$WORKER_DIR/wrangler.toml"
TOML_EXAMPLE="$WORKER_DIR/wrangler.toml.example"
WORKER_NAME="${WORKER_NAME:-cloud-mail}"

if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
fi

JWT_SECRET="${JWT_SECRET:-}"

cd "$WORKER_DIR"

echo "==> Checking wrangler auth..."
if ! npx wrangler whoami >/dev/null 2>&1; then
  echo "Not logged in. Opening browser for: wrangler login"
  npx wrangler login
fi

npx wrangler whoami

# Resolve account_id from wrangler whoami (no hardcoding)
ACCOUNT_ID="${CLOUDFLARE_ACCOUNT_ID:-$(npx wrangler whoami 2>/dev/null | grep -Eo '[0-9a-f]{32}' | head -1 || true)}"
if [[ -z "$ACCOUNT_ID" ]]; then
  echo "Could not determine Cloudflare account_id. Set CLOUDFLARE_ACCOUNT_ID env var."
  exit 1
fi
echo "ACCOUNT_ID=$ACCOUNT_ID"

echo "==> Ensuring wrangler.toml exists..."
if [[ ! -f "$TOML_FILE" ]]; then
  if [[ -f "$TOML_EXAMPLE" ]]; then
    cp "$TOML_EXAMPLE" "$TOML_FILE"
    echo "Created wrangler.toml from wrangler.toml.example"
  else
    echo "Neither wrangler.toml nor wrangler.toml.example found in $WORKER_DIR"
    exit 1
  fi
fi

echo "==> Reading domain/admin from wrangler.toml..."
MAIL_DOMAIN="${MAIL_DOMAIN:-}"
ADMIN_EMAIL="${ADMIN_EMAIL:-}"
if [[ -z "$MAIL_DOMAIN" ]]; then
  # Try [vars] domain first
  MAIL_DOMAIN="$(python3 -c "
import re
text = open('$TOML_FILE').read()
m = re.search(r'domain\s*=\s*\\[\"([^\"]+)\"\\]', text)
print(m.group(1) if m else '')
" 2>/dev/null || true)"
  if [[ -z "$MAIL_DOMAIN" ]]; then
    # Try routes pattern (e.g. mail.example.com -> example.com)
    ROUTE="$(python3 -c "
import re
text = open('$TOML_FILE').read()
m = re.search(r'pattern\s*=\s*[\"']([^\"']+)[\"']', text)
print(m.group(1) if m else '')
" 2>/dev/null || true)"
    if [[ -n "$ROUTE" ]]; then
      MAIL_DOMAIN="$(echo "$ROUTE" | sed 's/^[a-z]*\.//' 2>/dev/null || echo "$ROUTE")"
      echo "Derived MAIL_DOMAIN from route pattern: $MAIL_DOMAIN"
    fi
  fi
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
  ADMIN_EMAIL="$(python3 -c "
import re
text = open('$TOML_FILE').read()
m = re.search(r'admin\s*=\s*[\"']([^\"']+)[\"']', text)
print(m.group(1) if m else '')
" 2>/dev/null || true)"
fi
if [[ -z "$MAIL_DOMAIN" ]]; then
  read -rp "Enter your mail domain (e.g. example.com): " MAIL_DOMAIN
fi
if [[ -z "$ADMIN_EMAIL" ]]; then
  read -rp "Enter admin email (e.g. admin@example.com): " ADMIN_EMAIL
fi
echo "MAIL_DOMAIN=$MAIL_DOMAIN"
echo "ADMIN_EMAIL=$ADMIN_EMAIL"

echo "==> Checking existing jwt_secret..."
EXISTING_SECRETS="$(npx wrangler secret list 2>/dev/null || true)"
if echo "$EXISTING_SECRETS" | grep -q "jwt_secret"; then
  echo "jwt_secret already exists in Cloudflare — skipping (will NOT overwrite)"
  JWT_SECRET="<existing-in-cloud>"
else
  if [[ -z "$JWT_SECRET" ]]; then
    JWT_SECRET="$(openssl rand -hex 32)"
    echo "Generated new JWT_SECRET"
  fi
fi

echo "==> Ensuring D1 database: cloud-mail"
# Prefer known id from prior run / env; else parse `wrangler d1 list` text table
D1_ID="${D1_ID:-}"
if [[ -z "$D1_ID" ]]; then
  D1_LIST="$(npx wrangler d1 list 2>&1 || true)"
  D1_ID="$(echo "$D1_LIST" | grep -E 'cloud-mail' | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1 || true)"
fi
if [[ -z "$D1_ID" ]]; then
  echo "Creating D1..."
  CREATE_OUT="$(npx wrangler d1 create cloud-mail 2>&1)"
  echo "$CREATE_OUT"
  D1_ID="$(echo "$CREATE_OUT" | sed -n 's/.*database_id *= *"\([^"]*\)".*/\1/p' | head -1)"
  if [[ -z "$D1_ID" ]]; then
    D1_ID="$(echo "$CREATE_OUT" | grep -Eo '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  fi
fi
echo "D1_ID=$D1_ID"
[[ -n "$D1_ID" ]] || { echo "Failed to resolve D1 id"; exit 1; }

echo "==> Ensuring KV namespace: cloud-mail-kv"
# wrangler kv namespace list does not always support --json; parse plain output
KV_ID="${KV_ID:-}"
if [[ -z "$KV_ID" ]]; then
  KV_LIST="$(npx wrangler kv namespace list 2>&1 || true)"
  # JSON array form: [{"id":"...","title":"cloud-mail-kv"}]
  if echo "$KV_LIST" | grep -q 'cloud-mail-kv'; then
    KV_ID="$(echo "$KV_LIST" | python3 -c '
import sys, re, json
raw = sys.stdin.read()
# try JSON
try:
    data = json.loads(raw.strip() or "[]")
    if isinstance(data, dict):
        data = data.get("result") or []
    for n in data:
        if n.get("title") == "cloud-mail-kv":
            print(n.get("id") or "")
            break
except Exception:
    # fallback: line with title, grab nearby 32-hex id
    m = re.search(r"([0-9a-f]{32}).*cloud-mail-kv|cloud-mail-kv.*?([0-9a-f]{32})", raw, re.I|re.S)
    if m:
        print(m.group(1) or m.group(2) or "")
' 2>/dev/null || true)"
  fi
fi
if [[ -z "$KV_ID" ]]; then
  echo "Creating KV..."
  CREATE_OUT="$(npx wrangler kv namespace create cloud-mail-kv 2>&1)"
  echo "$CREATE_OUT"
  KV_ID="$(echo "$CREATE_OUT" | grep -Eo 'id\s*=\s*"[0-9a-f]{32}"' | grep -Eo '[0-9a-f]{32}' | head -1 || true)"
  if [[ -z "$KV_ID" ]]; then
    KV_ID="$(echo "$CREATE_OUT" | grep -Eo '[0-9a-f]{32}' | head -1 || true)"
  fi
fi
echo "KV_ID=$KV_ID"
[[ -n "$KV_ID" ]] || { echo "Failed to resolve KV id"; exit 1; }

echo "==> Patching wrangler.toml"
python3 - <<PY
from pathlib import Path
import re

p = Path("$TOML_FILE")
text = p.read_text()

# Replace placeholders
text = text.replace("REPLACE_D1_ID", "$D1_ID")
text = text.replace("REPLACE_KV_ID", "$KV_ID")

# Ensure account_id is set
if "account_id" not in text:
    text = text.replace('keep_vars = true', 'keep_vars = true\\naccount_id = "$ACCOUNT_ID"')
else:
    text = re.sub(r'account_id\s*=\s*"[^"]*"', 'account_id = "$ACCOUNT_ID"', text)

# Ensure domain var is set in [vars]
domain_line = 'domain = \'["$MAIL_DOMAIN"]\''
if re.search(r'^domain\s*=', text, re.M):
    text = re.sub(r'domain\s*=\s*.+', domain_line, text)
else:
    # Uncomment or add after [vars]
    if '[vars]' in text:
        text = text.replace('[vars]', '[vars]\\n' + domain_line)
    else:
        text += '\\n[vars]\\n' + domain_line + '\\n'

# Ensure admin var is set
admin_line = 'admin = "$ADMIN_EMAIL"'
if re.search(r'^admin\s*=', text, re.M):
    text = re.sub(r'admin\s*=\s*".+"', admin_line, text)
else:
    text = re.sub(r'(domain\s*=\s*.+)', r'\\1\\n' + admin_line, text)

# Ensure routes pattern is set (uncomment if needed)
route_block = '[[routes]]\\npattern = "mail.$MAIL_DOMAIN"\\ncustom_domain = true'
if '[[routes]]' not in text:
    text = text.replace('[observability]', route_block + '\\n\\n[observability]')
else:
    text = re.sub(r'pattern\s*=\s*"[^"]+"', 'pattern = "mail.$MAIL_DOMAIN"', text)

p.write_text(text)
print("wrangler.toml updated with D1/KV IDs, domain, admin, account_id")
PY

python3 - <<PY
import json
from pathlib import Path
Path("$IDS_FILE").write_text(json.dumps({
  "account_id": "$ACCOUNT_ID",
  "d1_id": "$D1_ID",
  "kv_id": "$KV_ID",
  "mail_domain": "$MAIL_DOMAIN",
  "admin_email": "$ADMIN_EMAIL",
  "worker_name": "$WORKER_NAME",
  "zone_id": "${ZONE_ID:-}",
}, indent=2))
print("wrote $IDS_FILE")
PY

echo "==> Installing dependencies"
pnpm install
pnpm --prefix ../mail-vue install

echo "==> Setting jwt_secret (only if not already in Cloudflare)"
if [[ "$JWT_SECRET" == "<existing-in-cloud>" ]]; then
  echo "Skipping — jwt_secret already exists, keeping existing value."
else
  printf '%s' "$JWT_SECRET" | npx wrangler secret put jwt_secret
fi

echo "==> Deploying worker (builds Vue frontend)..."
pnpm run deploy

echo "==> Binding custom domain (optional workers.dev always works)"
# workers.dev: cloud-mail.<subdomain>.workers.dev
# Custom domain on the zone — best effort
npx wrangler domains add "$MAIL_DOMAIN" 2>/dev/null || true
npx wrangler domains add "mail.$MAIL_DOMAIN" 2>/dev/null || true

echo "==> Configure Email Routing catch-all → worker via API if token available"
ZONE_ID="${ZONE_ID:-}"
if [[ -n "${CLOUDFLARE_API_TOKEN:-}" && -n "$ZONE_ID" ]]; then
  curl -sS -X PUT \
    "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/email/routing/rules/catch_all" \
    -H "Authorization: Bearer ${CLOUDFLARE_API_TOKEN}" \
    -H "Content-Type: application/json" \
    --data '{
      "matchers": [{"type":"all"}],
      "actions": [{"type":"worker","value":["'"$WORKER_NAME"'"]}],
      "enabled": true,
      "name": "cloud-mail catch-all"
    }' | python3 -m json.tool || true
else
  echo "Set catch-all in Dashboard (or provide CLOUDFLARE_API_TOKEN + ZONE_ID):"
  echo "  Zone $MAIL_DOMAIN → Email Routing → Catch-all → Send to Worker: $WORKER_NAME"
fi

echo ""
echo "=============================================="
echo "Deploy done."
echo "1) Open: https://${WORKER_NAME}.<your-subdomain>.workers.dev"
echo "   or your custom domain"
if [[ "$JWT_SECRET" != "<existing-in-cloud>" ]]; then
echo "2) Init DB once:"
echo "   https://<host>/api/init/${JWT_SECRET}"
else
echo "2) jwt_secret already existed — DB should already be initialized."
fi
echo "3) Register/login as admin: $ADMIN_EMAIL"
echo "4) (Optional) Resend API key in system settings for sending"
echo "5) Email Routing catch-all → Worker $WORKER_NAME"
echo "=============================================="
if [[ "$JWT_SECRET" != "<existing-in-cloud>" ]]; then
echo "JWT is in $SECRETS_FILE — keep it private."
# refresh secrets file with jwt used
cat > "$SECRETS_FILE" <<EOF
# Local only — do not commit
export CLOUDFLARE_ACCOUNT_ID=$ACCOUNT_ID
export JWT_SECRET=$JWT_SECRET
export MAIL_DOMAIN=$MAIL_DOMAIN
export ADMIN_EMAIL=$ADMIN_EMAIL
export WORKER_NAME=$WORKER_NAME
${ZONE_ID:+export ZONE_ID=$ZONE_ID}
EOF
else
echo "jwt_secret was not regenerated — $SECRETS_FILE not updated."
fi
