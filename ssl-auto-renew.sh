#!/bin/bash

# ============================================================
# Nginx LB SSL Auto Renewal
# ============================================================
# Purpose:
#   - Discover domains from /etc/nginx/conf.d/*.conf
#   - Check each domain's SSL certificate once
#   - Store certificate expiry and next-check date in state
#   - Do NOT check SSL every day
#   - Re-check the live certificate only when threshold is reached
#   - Renew with certbot when the live certificate has <= threshold days
#   - Log all activity and renewal errors
#
# Recommended cron:
#   0 2 * * * /usr/local/bin/ssl-auto-renew.sh
#
# ============================================================

set -u
umask 022

# -----------------------------
# Configuration
# -----------------------------
NGINX_CONF_DIR="/etc/nginx/conf.d"
THRESHOLD_DAYS=12

STATE_DIR="/var/lib/ssl-auto-renew"
STATE_FILE="${STATE_DIR}/state"
LOG_FILE="/var/log/ssl-auto-renew.log"

LOCK_FILE="/run/ssl-auto-renew.lock"

# -----------------------------
# Logging
# -----------------------------
log() {
    printf '%s - %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"
}

# -----------------------------
# Lock
# Prevent overlapping cron runs
# -----------------------------
exec 9>"$LOCK_FILE"

if ! flock -n 9; then
    log "Another instance is already running. Exiting."
    exit 0
fi

# -----------------------------
# Initial setup
# -----------------------------
mkdir -p "$STATE_DIR"
touch "$STATE_FILE" "$LOG_FILE"

# -----------------------------
# Calculate epoch
# -----------------------------
date_to_epoch() {
    date -d "$1" +%s 2>/dev/null
}

# -----------------------------
# Calculate days remaining
# -----------------------------
days_remaining() {
    local expiry="$1"
    local expiry_epoch
    local now_epoch

    expiry_epoch=$(date_to_epoch "$expiry") || {
        echo "-1"
        return
    }

    now_epoch=$(date +%s)

    echo $(( (expiry_epoch - now_epoch) / 86400 ))
}

# -----------------------------
# Calculate threshold date
# expiry - THRESHOLD_DAYS
# -----------------------------
threshold_date() {
    date -d "$1 - ${THRESHOLD_DAYS} days" '+%Y-%m-%d'
}

# -----------------------------
# Get live certificate expiry
#
# This is intentionally called ONLY
# on initial discovery or threshold day.
# -----------------------------
get_live_ssl_expiry() {
    local domain="$1"

    echo | timeout 20 openssl s_client \
        -servername "$domain" \
        -connect "${domain}:443" \
        2>/dev/null |
        openssl x509 -noout -enddate 2>/dev/null |
        cut -d= -f2
}

# -----------------------------
# Normalize domain
# -----------------------------
normalize_domain() {
    local domain="$1"

    domain="${domain#http://}"
    domain="${domain#https://}"
    domain="${domain%%/*}"
    domain="${domain,,}"

    echo "$domain"
}

# -----------------------------
# Check whether domain is valid
# -----------------------------
valid_domain() {
    local domain="$1"

    [[ "$domain" =~ ^[A-Za-z0-9.-]+$ ]] || return 1
    [[ "$domain" != *".."* ]] || return 1
    [[ "$domain" != .* ]] || return 1
    [[ "$domain" != -* ]] || return 1

    return 0
}

# -----------------------------
# Discover server_name values
# -----------------------------
discover_domains() {
    grep -RhoE '^[[:space:]]*server_name[[:space:]]+[^;]+' \
        "$NGINX_CONF_DIR"/*.conf 2>/dev/null |
    sed -E 's/^[[:space:]]*server_name[[:space:]]+//' |
    tr ' ' '\n' |
    tr '\t' '\n' |
    sed 's/[;]//g' |
    while IFS= read -r domain; do
        domain=$(normalize_domain "$domain")

        # Skip wildcard, localhost and variables
        [[ "$domain" == \** ]] && continue
        [[ "$domain" == "localhost" ]] && continue
        [[ "$domain" == *'$'* ]] && continue
        [[ -z "$domain" ]] && continue

        if valid_domain "$domain"; then
            echo "$domain"
        fi
    done |
    sort -u
}

# -----------------------------
# Find ssl_certificate associated
# with a server_name.
#
# This parser handles common nginx
# server blocks and keeps the
# certificate associated with the
# matching server block.
# -----------------------------
get_cert_for_domain() {
    local target="$1"
    local file
    local content
    local block
    local depth
    local current
    local found

    shopt -s nullglob

    for file in "$NGINX_CONF_DIR"/*.conf; do

        # Read file and remove comments.
        content=$(sed -E 's/[[:space:]]*#.*$//' "$file")

        # Extract approximate server blocks.
        while IFS= read -r block; do

            if echo "$block" |
                grep -Eq "(^|[[:space:];])server_name[[:space:]]+[^;]*([[:space:]]|^)${target}([[:space:];]|$)"; then

                found=$(echo "$block" |
                    grep -Eo 'ssl_certificate[[:space:]]+[^;]+' |
                    head -1 |
                    sed -E 's/ssl_certificate[[:space:]]+//')

                if [[ -n "$found" ]]; then
                    echo "$found"
                    shopt -u nullglob
                    return 0
                fi
            fi

        done < <(
            awk '
            BEGIN { depth=0; block="" }

            /server[[:space:]]*\{/ {
                depth=1
                block=$0 "\n"
                next
            }

            depth > 0 {
                block=block $0 "\n"

                opens=gsub(/\{/, "{")
                closes=gsub(/\}/, "}")

                depth += opens - closes

                if (depth <= 0) {
                    print block
                    block=""
                    depth=0
                }
            }
            ' <<< "$content"
        )
    done

    shopt -u nullglob
    return 1
}

# -----------------------------
# State handling
#
# Format:
# domain|cert_path|expiry|next_check
# -----------------------------
get_state() {
    local domain="$1"

    awk -F'|' -v d="$domain" '$1 == d { print; exit }' "$STATE_FILE"
}

save_state() {
    local domain="$1"
    local cert="$2"
    local expiry="$3"
    local next_check="$4"
    local tmp

    tmp="${STATE_FILE}.tmp"

    awk -F'|' -v d="$domain" '$1 != d' "$STATE_FILE" > "$tmp"

    printf '%s|%s|%s|%s\n' \
        "$domain" "$cert" "$expiry" "$next_check" >> "$tmp"

    mv "$tmp" "$STATE_FILE"
}

remove_state() {
    local domain="$1"
    local tmp="${STATE_FILE}.tmp"

    awk -F'|' -v d="$domain" '$1 != d' "$STATE_FILE" > "$tmp"
    mv "$tmp" "$STATE_FILE"
}

# -----------------------------
# Renew certificate
# -----------------------------
renew_certificate() {
    local domain="$1"

    log "Starting Certbot renewal: $domain"

    if certbot --nginx -d "$domain" --force-renewal >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: Certbot renewal completed for $domain"
        return 0
    else
        log "ERROR: Certbot renewal FAILED for $domain"
        return 1
    fi
}

# -----------------------------
# Validate nginx after renewal
# -----------------------------
reload_nginx() {

    log "Running nginx configuration test"

    if nginx -t >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: nginx configuration test passed"
    else
        log "ERROR: nginx configuration test FAILED"
        return 1
    fi

    if systemctl reload nginx >> "$LOG_FILE" 2>&1; then
        log "SUCCESS: nginx reloaded"
        return 0
    else
        log "ERROR: nginx reload FAILED"
        return 1
    fi
}

# ============================================================
# MAIN
# ============================================================

log "========== SSL AUTO RENEW START =========="

TODAY=$(date '+%Y-%m-%d')

mapfile -t DOMAINS < <(discover_domains)

if [[ "${#DOMAINS[@]}" -eq 0 ]]; then
    log "WARNING: No domains discovered under $NGINX_CONF_DIR"
    log "========== SSL AUTO RENEW END =========="
    exit 0
fi

for domain in "${DOMAINS[@]}"; do

    state=$(get_state "$domain")

    # ========================================================
    # FIRST DISCOVERY
    #
    # SSL is checked here only once.
    # ========================================================
    if [[ -z "$state" ]]; then

        log "NEW DOMAIN DISCOVERED: $domain"

        cert_file=$(get_cert_for_domain "$domain" || true)

        if [[ -z "$cert_file" ]]; then
            log "WARNING: Could not find ssl_certificate for $domain"
            continue
        fi

        # Expand relative certificate path if necessary.
        if [[ "$cert_file" != /* ]]; then
            cert_file="/etc/nginx/$cert_file"
        fi

        if [[ ! -f "$cert_file" ]]; then
            log "WARNING: Certificate file does not exist: $cert_file"
            continue
        fi

        expiry=$(openssl x509 \
            -in "$cert_file" \
            -noout -enddate 2>/dev/null |
            cut -d= -f2)

        if [[ -z "$expiry" ]]; then
            log "ERROR: Cannot read certificate expiry for $domain"
            continue
        fi

        expiry_date=$(date -d "$expiry" '+%Y-%m-%d' 2>/dev/null)

        if [[ -z "$expiry_date" ]]; then
            log "ERROR: Cannot parse certificate expiry for $domain"
            continue
        fi

        next_check=$(threshold_date "$expiry_date")

        save_state "$domain" "$cert_file" "$expiry_date" "$next_check"

        days=$(days_remaining "$expiry")

        log "INITIAL CHECK: $domain"
        log "Certificate: $cert_file"
        log "Expiry: $expiry"
        log "Days remaining: $days"
        log "Next SSL check: $next_check"

        # If already inside threshold, don't blindly renew.
        # The next block will perform the live confirmation.
        if [[ "$TODAY" < "$next_check" ]]; then
            continue
        fi

    fi

    # ========================================================
    # EXISTING DOMAIN
    # ========================================================

    state=$(get_state "$domain")

    IFS='|' read -r state_domain state_cert state_expiry state_next_check <<< "$state"

    # Not threshold day yet.
    if [[ "$TODAY" < "$state_next_check" ]]; then
        continue
    fi

    # ========================================================
    # THRESHOLD REACHED
    #
    # NOW we perform the live SSL check.
    # ========================================================

    log "THRESHOLD REACHED: $domain"
    log "Stored expiry: $state_expiry"
    log "Stored next check: $state_next_check"

    live_expiry=$(get_live_ssl_expiry "$domain")

    if [[ -z "$live_expiry" ]]; then
        log "ERROR: Could not retrieve LIVE SSL certificate for $domain"
        continue
    fi

    live_expiry_date=$(date -d "$live_expiry" '+%Y-%m-%d' 2>/dev/null)

    if [[ -z "$live_expiry_date" ]]; then
        log "ERROR: Could not parse LIVE SSL expiry for $domain"
        continue
    fi

    live_days=$(days_remaining "$live_expiry")

    log "LIVE SSL: $domain"
    log "Live expiry: $live_expiry"
    log "Live days remaining: $live_days"

    # ========================================================
    # LIVE CERTIFICATE STILL HAS MORE THAN THRESHOLD DAYS
    #
    # This normally means the certificate was already renewed
    # externally or the stored certificate was stale.
    #
    # Update state and wait for the new threshold.
    # ========================================================

    if (( live_days > THRESHOLD_DAYS )); then

        new_next_check=$(threshold_date "$live_expiry_date")

        save_state \
            "$domain" \
            "$state_cert" \
            "$live_expiry_date" \
            "$new_next_check"

        log "LIVE certificate is not due for renewal."
        log "State updated."
        log "New expiry: $live_expiry_date"
        log "New next check: $new_next_check"

        continue
    fi

    # ========================================================
    # LIVE CERTIFICATE IS AT / BELOW THRESHOLD
    # ========================================================

    log "CONFIRMED: $domain has <= $THRESHOLD_DAYS days remaining"
    log "Starting renewal."

    if renew_certificate "$domain"; then

        # ----------------------------------------------------
        # Read the certificate again after renewal.
        # This confirms what is actually installed on disk.
        # ----------------------------------------------------

        new_cert_file=$(get_cert_for_domain "$domain" || true)

        if [[ -z "$new_cert_file" ]]; then
            new_cert_file="$state_cert"
        fi

        if [[ "$new_cert_file" != /* ]]; then
            new_cert_file="/etc/nginx/$new_cert_file"
        fi

        new_expiry=$(openssl x509 \
            -in "$new_cert_file" \
            -noout -enddate 2>/dev/null |
            cut -d= -f2)

        if [[ -n "$new_expiry" ]]; then

            new_expiry_date=$(date -d "$new_expiry" '+%Y-%m-%d' 2>/dev/null)

            if [[ -n "$new_expiry_date" ]]; then

                new_next_check=$(threshold_date "$new_expiry_date")

                save_state \
                    "$domain" \
                    "$new_cert_file" \
                    "$new_expiry_date" \
                    "$new_next_check"

                log "NEW certificate expiry: $new_expiry"
                log "Next SSL check: $new_next_check"

            else
                log "WARNING: Could not parse renewed certificate expiry for $domain"
            fi

        else
            log "WARNING: Could not read renewed certificate for $domain"
        fi

        # ----------------------------------------------------
        # Validate and reload nginx
        # ----------------------------------------------------

        reload_nginx || true

    else

        # Renewal failed.
        # Retry on next cron run because the state remains
        # due (next_check <= TODAY).
        log "Renewal failed for $domain."
        log "The domain remains due and will be retried on the next cron run."

    fi

done

log "========== SSL AUTO RENEW END =========="
log ""
exit 0
