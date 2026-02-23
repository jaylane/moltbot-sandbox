#!/bin/bash
# Startup script for OpenClaw in Cloudflare Sandbox
# This script:
# 1. Restores config/workspace/skills from R2 via rclone (if configured)
# 2. Runs openclaw onboard --non-interactive to configure from env vars
# 3. Patches config for features onboard doesn't cover (channels, gateway auth)
# 4. Starts a background sync loop (rclone, watches for file changes)
# 5. Starts the gateway


set -e


if pgrep -f "openclaw gateway" > /dev/null 2>&1; then
    echo "OpenClaw gateway is already running, exiting."
    exit 0
fi


CONFIG_DIR="/root/.openclaw"
CONFIG_FILE="$CONFIG_DIR/openclaw.json"
WORKSPACE_DIR="/root/clawd"
SKILLS_DIR="/root/clawd/skills"
RCLONE_CONF="/root/.config/rclone/rclone.conf"
LAST_SYNC_FILE="/tmp/.last-sync"


echo "Config directory: $CONFIG_DIR"


mkdir -p "$CONFIG_DIR"


# ============================================================
# RCLONE SETUP
# ============================================================


r2_configured() {
    [ -n "$R2_ACCESS_KEY_ID" ] && [ -n "$R2_SECRET_ACCESS_KEY" ] && [ -n "$CF_ACCOUNT_ID" ]
}


R2_BUCKET="${R2_BUCKET_NAME:-moltbot-data}"


setup_rclone() {
    mkdir -p "$(dirname "$RCLONE_CONF")"
    cat > "$RCLONE_CONF" << EOF
[r2]
type = s3
provider = Cloudflare
access_key_id = $R2_ACCESS_KEY_ID
secret_access_key = $R2_SECRET_ACCESS_KEY
endpoint = https://${CF_ACCOUNT_ID}.r2.cloudflarestorage.com
acl = private
no_check_bucket = true
EOF
    touch /tmp/.rclone-configured
    echo "Rclone configured for bucket: $R2_BUCKET"
}


RCLONE_FLAGS="--transfers=16 --fast-list --s3-no-check-bucket"


# ============================================================
# RESTORE FROM R2
# ============================================================


if r2_configured; then
    setup_rclone


    echo "Checking R2 for existing backup..."
    # Check if R2 has an openclaw config backup
    if rclone ls "r2:${R2_BUCKET}/openclaw/openclaw.json" $RCLONE_FLAGS 2>/dev/null | grep -q openclaw.json; then
        echo "Restoring config from R2..."
        rclone copy "r2:${R2_BUCKET}/openclaw/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: config restore failed with exit code $?"
        echo "Config restored"
    elif rclone ls "r2:${R2_BUCKET}/clawdbot/clawdbot.json" $RCLONE_FLAGS 2>/dev/null | grep -q clawdbot.json; then
        echo "Restoring from legacy R2 backup..."
        rclone copy "r2:${R2_BUCKET}/clawdbot/" "$CONFIG_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: legacy config restore failed with exit code $?"
        if [ -f "$CONFIG_DIR/clawdbot.json" ] && [ ! -f "$CONFIG_FILE" ]; then
            mv "$CONFIG_DIR/clawdbot.json" "$CONFIG_FILE"
        fi
        echo "Legacy config restored and migrated"
    else
        echo "No backup found in R2, starting fresh"
    fi


    # Restore workspace
    REMOTE_WS_COUNT=$(rclone ls "r2:${R2_BUCKET}/workspace/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_WS_COUNT" -gt 0 ]; then
        echo "Restoring workspace from R2 ($REMOTE_WS_COUNT files)..."
        mkdir -p "$WORKSPACE_DIR"
        rclone copy "r2:${R2_BUCKET}/workspace/" "$WORKSPACE_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: workspace restore failed with exit code $?"
        echo "Workspace restored"
    fi


    # Restore skills
    REMOTE_SK_COUNT=$(rclone ls "r2:${R2_BUCKET}/skills/" $RCLONE_FLAGS 2>/dev/null | wc -l)
    if [ "$REMOTE_SK_COUNT" -gt 0 ]; then
        echo "Restoring skills from R2 ($REMOTE_SK_COUNT files)..."
        mkdir -p "$SKILLS_DIR"
        rclone copy "r2:${R2_BUCKET}/skills/" "$SKILLS_DIR/" $RCLONE_FLAGS -v 2>&1 || echo "WARNING: skills restore failed with exit code $?"
        echo "Skills restored"
    fi
else
    echo "R2 not configured, starting fresh"
fi


# ============================================================
# ONBOARD (only if no config exists yet)
# ============================================================
if [ ! -f "$CONFIG_FILE" ]; then
    echo "No existing config found, running openclaw onboard..."


    AUTH_ARGS=""
    if [ -n "$CLOUDFLARE_AI_GATEWAY_API_KEY" ] && [ -n "$CF_AI_GATEWAY_ACCOUNT_ID" ] && [ -n "$CF_AI_GATEWAY_GATEWAY_ID" ]; then
        AUTH_ARGS="--auth-choice cloudflare-ai-gateway-api-key \
            --cloudflare-ai-gateway-account-id $CF_AI_GATEWAY_ACCOUNT_ID \
            --cloudflare-ai-gateway-gateway-id $CF_AI_GATEWAY_GATEWAY_ID \
            --cloudflare-ai-gateway-api-key $CLOUDFLARE_AI_GATEWAY_API_KEY"
    elif [ -n "$ANTHROPIC_API_KEY" ]; then
        AUTH_ARGS="--auth-choice apiKey --anthropic-api-key $ANTHROPIC_API_KEY"
    elif [ -n "$OPENAI_API_KEY" ]; then
        AUTH_ARGS="--auth-choice openai-api-key --openai-api-key $OPENAI_API_KEY"
    fi


    openclaw onboard --non-interactive --accept-risk \
        --mode local \
        $AUTH_ARGS \
        --gateway-port 18789 \
        --gateway-bind lan \
        --skip-channels \
        --skip-skills \
        --skip-health


    echo "Onboard completed"
else
    echo "Using existing config"
fi


# ============================================================
# PATCH CONFIG (channels, gateway auth, trusted proxies)
# ============================================================
# openclaw onboard handles provider/model config, but we need to patch in:
# - Channel config (Telegram, Discord, Slack)
# - Gateway token auth
# - Trusted proxies for sandbox networking
# - Base URL override for legacy AI Gateway path
#
# IMPORTANT: This script MERGES into existing config — it never overwrites
# settings that were configured at runtime (e.g. via config.patch or the UI).
# Env var tokens are always injected (they may rotate), but all other fields
# (dmPolicy, groupPolicy, dm.allowFrom, etc.) are only set as defaults when
# the channel section doesn't already exist.
node << 'EOFPATCH'
const fs = require('fs');


const configPath = '/root/.openclaw/openclaw.json';
console.log('Patching config at:', configPath);
let config = {};


try {
    config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
    const size = JSON.stringify(config).length;
    console.log('Loaded existing config (' + size + ' bytes)');
} catch (e) {
    console.log('Starting with empty config');
}


// ---- helpers ----


// Shallow merge: set key on target only if it doesn't already exist
function defaults(target, src) {
    for (const [k, v] of Object.entries(src)) {
        if (target[k] === undefined) {
            target[k] = v;
        }
    }
    return target;
}


// Deep merge: recursively merge src into target, never overwriting existing leaves
function deepDefaults(target, src) {
    for (const [k, v] of Object.entries(src)) {
        if (target[k] === undefined) {
            target[k] = v;
        } else if (v && typeof v === 'object' && !Array.isArray(v) &&
                   target[k] && typeof target[k] === 'object' && !Array.isArray(target[k])) {
            deepDefaults(target[k], v);
        }
        // else: target[k] already exists as a leaf/array — don't touch it
    }
    return target;
}


// ---- gateway ----


config.gateway = config.gateway || {};
// These are infrastructure constants for the sandbox — always set
config.gateway.port = 18789;
config.gateway.mode = 'local';
config.gateway.trustedProxies = ['10.1.0.0'];


if (process.env.OPENCLAW_GATEWAY_TOKEN) {
    config.gateway.auth = config.gateway.auth || {};
    // Always inject token (may rotate between deploys)
    config.gateway.auth.token = process.env.OPENCLAW_GATEWAY_TOKEN;
}


if (process.env.OPENCLAW_DEV_MODE === 'true') {
    config.gateway.controlUi = config.gateway.controlUi || {};
    config.gateway.controlUi.allowInsecureAuth = true;
}


config.channels = config.channels || {};


// Legacy AI Gateway base URL override:
// ANTHROPIC_BASE_URL is picked up natively by the Anthropic SDK,
// so we don't need to patch the provider config. Writing a provider
// entry without a models array breaks OpenClaw's config validation.


// AI Gateway model override (CF_AI_GATEWAY_MODEL=provider/model-id)
// Only applied when no model config exists yet (fresh install).
if (process.env.CF_AI_GATEWAY_MODEL) {
    const raw = process.env.CF_AI_GATEWAY_MODEL;
    const slashIdx = raw.indexOf('/');
    const gwProvider = raw.substring(0, slashIdx);
    const modelId = raw.substring(slashIdx + 1);


    const accountId = process.env.CF_AI_GATEWAY_ACCOUNT_ID;
    const gatewayId = process.env.CF_AI_GATEWAY_GATEWAY_ID;
    const apiKey = process.env.CLOUDFLARE_AI_GATEWAY_API_KEY;


    let baseUrl;
    if (accountId && gatewayId) {
        baseUrl = 'https://gateway.ai.cloudflare.com/v1/' + accountId + '/' + gatewayId + '/' + gwProvider;
        if (gwProvider === 'workers-ai') baseUrl += '/v1';
    } else if (gwProvider === 'workers-ai' && process.env.CF_ACCOUNT_ID) {
        baseUrl = 'https://api.cloudflare.com/client/v4/accounts/' + process.env.CF_ACCOUNT_ID + '/ai/v1';
    }


    if (baseUrl && apiKey) {
        const api = gwProvider === 'anthropic' ? 'anthropic-messages' : 'openai-completions';
        const providerName = 'cf-ai-gw-' + gwProvider;


        config.models = config.models || {};
        config.models.providers = config.models.providers || {};
        // Only add the AI GW provider if not already configured
        if (!config.models.providers[providerName]) {
            config.models.providers[providerName] = {
                baseUrl: baseUrl,
                apiKey: apiKey,
                api: api,
                models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
            };
            console.log('AI Gateway model override: provider=' + providerName + ' model=' + modelId + ' via ' + baseUrl);
        } else {
            // Always update the API key (may rotate)
            config.models.providers[providerName].apiKey = apiKey;
            console.log('AI Gateway provider exists, updated API key only');
        }
        // Only set default model if not already configured
        config.agents = config.agents || {};
        config.agents.defaults = config.agents.defaults || {};
        if (!config.agents.defaults.model) {
            config.agents.defaults.model = { primary: providerName + '/' + modelId };
        }
    } else {
        console.warn('CF_AI_GATEWAY_MODEL set but missing required config (account ID, gateway ID, or API key)');
    }
}


// ---- Telegram ----
// Always inject the token from env (it may rotate). For all other settings,
// only apply defaults if the channel section didn't already exist.
if (process.env.TELEGRAM_BOT_TOKEN) {
    const isNew = !config.channels.telegram;
    config.channels.telegram = config.channels.telegram || {};
    // Always set token + enabled (token may rotate between deploys)
    config.channels.telegram.botToken = process.env.TELEGRAM_BOT_TOKEN;
    config.channels.telegram.enabled = true;


    if (isNew) {
        // First-time defaults only
        const dmPolicy = process.env.TELEGRAM_DM_POLICY || 'pairing';
        config.channels.telegram.dmPolicy = dmPolicy;
        if (process.env.TELEGRAM_DM_ALLOW_FROM) {
            config.channels.telegram.allowFrom = process.env.TELEGRAM_DM_ALLOW_FROM.split(',');
        } else if (dmPolicy === 'open') {
            config.channels.telegram.allowFrom = ['*'];
        }
        console.log('Telegram: new channel configured (dmPolicy=' + dmPolicy + ')');
    } else {
        console.log('Telegram: updated token, preserved existing settings');
    }
}


// ---- Discord ----
if (process.env.DISCORD_BOT_TOKEN) {
    const isNew = !config.channels.discord;
    config.channels.discord = config.channels.discord || {};
    config.channels.discord.token = process.env.DISCORD_BOT_TOKEN;
    config.channels.discord.enabled = true;


    if (isNew) {
        const dmPolicy = process.env.DISCORD_DM_POLICY || 'pairing';
        const dm = { policy: dmPolicy };
        if (dmPolicy === 'open') {
            dm.allowFrom = ['*'];
        }
        config.channels.discord.dm = dm;
        console.log('Discord: new channel configured (dmPolicy=' + dmPolicy + ')');
    } else {
        console.log('Discord: updated token, preserved existing settings');
    }
}


// ---- Slack ----
if (process.env.SLACK_BOT_TOKEN && process.env.SLACK_APP_TOKEN) {
    const isNew = !config.channels.slack;
    config.channels.slack = config.channels.slack || {};
    // Always inject tokens (may rotate)
    config.channels.slack.botToken = process.env.SLACK_BOT_TOKEN;
    config.channels.slack.appToken = process.env.SLACK_APP_TOKEN;
    config.channels.slack.enabled = true;


    if (isNew) {
        console.log('Slack: new channel configured');
    } else {
        console.log('Slack: updated tokens, preserved existing settings');
    }
}


// ---- Write ----
const output = JSON.stringify(config, null, 2);
fs.writeFileSync(configPath, output);
console.log('Configuration patched successfully (' + output.length + ' bytes)');
EOFPATCH


# ============================================================
# BACKGROUND SYNC LOOP
# ============================================================
if r2_configured; then
    echo "Starting background R2 sync loop..."
    (
        MARKER=/tmp/.last-sync-marker
        LOGFILE=/tmp/r2-sync.log
        touch "$MARKER"


        while true; do
            sleep 30


            CHANGED=/tmp/.changed-files
            {
                find "$CONFIG_DIR" -newer "$MARKER" -type f -printf '%P\n' 2>/dev/null
                find "$WORKSPACE_DIR" -newer "$MARKER" \
                    -not -path '*/node_modules/*' \
                    -not -path '*/.git/*' \
                    -type f -printf '%P\n' 2>/dev/null
            } > "$CHANGED"


            COUNT=$(wc -l < "$CHANGED" 2>/dev/null || echo 0)


            if [ "$COUNT" -gt 0 ]; then
                # Safety check: refuse to sync a suspiciously small config to R2
                # A healthy config is typically 3KB+; a skeleton is ~600 bytes
                CONFIG_SIZE=$(stat -c%s "$CONFIG_DIR/openclaw.json" 2>/dev/null || echo 0)
                if [ "$CONFIG_SIZE" -lt 2000 ]; then
                    echo "[sync] WARNING: config is only ${CONFIG_SIZE} bytes — refusing to sync (likely corrupted)" >> "$LOGFILE"
                    touch "$MARKER"
                    continue
                fi


                echo "[sync] Uploading changes ($COUNT files, config=${CONFIG_SIZE}b) at $(date)" >> "$LOGFILE"
                rclone sync "$CONFIG_DIR/" "r2:${R2_BUCKET}/openclaw/" \
                    $RCLONE_FLAGS --exclude='*.lock' --exclude='*.log' --exclude='*.tmp' --exclude='.git/**' 2>> "$LOGFILE"
                if [ -d "$WORKSPACE_DIR" ]; then
                    rclone sync "$WORKSPACE_DIR/" "r2:${R2_BUCKET}/workspace/" \
                        $RCLONE_FLAGS --exclude='skills/**' --exclude='.git/**' --exclude='node_modules/**' 2>> "$LOGFILE"
                fi
                if [ -d "$SKILLS_DIR" ]; then
                    rclone sync "$SKILLS_DIR/" "r2:${R2_BUCKET}/skills/" \
                        $RCLONE_FLAGS 2>> "$LOGFILE"
                fi
                date -Iseconds > "$LAST_SYNC_FILE"
                touch "$MARKER"
                echo "[sync] Complete at $(date)" >> "$LOGFILE"
            fi
        done
    ) &
    echo "Background sync loop started (PID: $!)"
fi


# ============================================================
# START GATEWAY
# ============================================================
echo "Starting OpenClaw Gateway..."
echo "Gateway will be available on port 18789"


rm -f /tmp/openclaw-gateway.lock 2>/dev/null || true
rm -f "$CONFIG_DIR/gateway.lock" 2>/dev/null || true


echo "Dev mode: ${OPENCLAW_DEV_MODE:-false}"


if [ -n "$OPENCLAW_GATEWAY_TOKEN" ]; then
    echo "Starting gateway with token auth..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan --token "$OPENCLAW_GATEWAY_TOKEN"
else
    echo "Starting gateway with device pairing (no token)..."
    exec openclaw gateway --port 18789 --verbose --allow-unconfigured --bind lan
fi

