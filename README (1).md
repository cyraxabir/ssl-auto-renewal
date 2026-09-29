# Nginx LB SSL Auto Renewal

A stateful Bash script for automatically renewing Nginx SSL certificates with Certbot.

The script is designed for an Nginx Load Balancer VM where multiple domains are configured under:

```text
/etc/nginx/conf.d/*.conf
```

## Features

- Discovers domains from Nginx `server_name` directives.
- Associates a domain with its `ssl_certificate`.
- Checks the certificate expiry when a domain is first discovered.
- Does **not** check SSL expiry every day.
- Stores state in:

```text
/var/lib/ssl-auto-renew/state
```

- Calculates the next check date as:

```text
certificate expiry date - THRESHOLD_DAYS
```

- Default threshold:

```text
12 days
```

- At the threshold date, performs a fresh live SSL check using:

```bash
echo | openssl s_client \
  -servername mydomain.com \
  -connect mydomain.com:443 2>/dev/null |
  openssl x509 -noout -enddate
```

- If the live certificate has `<= 12` days remaining, it runs:

```bash
certbot --nginx -d mydomain.com --force-renewal
```

- Logs successful and failed renewals.
- Validates Nginx configuration after successful renewal.
- Reloads Nginx after successful renewal.
- Uses a lock to prevent overlapping executions.
- If renewal fails, the domain remains due and is retried on the next cron run.

---

# 1. Requirements

The LB VM should have:

- Bash
- Nginx
- OpenSSL
- Certbot
- Certbot Nginx plugin
- `flock`
- GNU `date`

Check:

```bash
bash --version
nginx -v
openssl version
certbot --version
flock --version
```

Check the Certbot Nginx plugin:

```bash
certbot plugins
```

You should see the Nginx plugin.

---

# 2. Install

Copy the script:

```bash
sudo cp ssl-auto-renew.sh /usr/local/bin/ssl-auto-renew.sh
```

Make it executable:

```bash
sudo chmod 750 /usr/local/bin/ssl-auto-renew.sh
```

Create the state directory:

```bash
sudo mkdir -p /var/lib/ssl-auto-renew
sudo chmod 750 /var/lib/ssl-auto-renew
```

Create the log file:

```bash
sudo touch /var/log/ssl-auto-renew.log
sudo chmod 640 /var/log/ssl-auto-renew.log
```

---

# 3. Configure threshold

Edit:

```bash
sudo vi /usr/local/bin/ssl-auto-renew.sh
```

Default:

```bash
THRESHOLD_DAYS=12
```

For example, to renew at 15 days:

```bash
THRESHOLD_DAYS=15
```

---

# 4. Test manually

Before adding cron, run:

```bash
sudo /usr/local/bin/ssl-auto-renew.sh
```

Watch the log:

```bash
sudo tail -f /var/log/ssl-auto-renew.log
```

---

# 5. First run behavior

Suppose:

```text
example.com
Certificate expiry: 2026-12-20
THRESHOLD_DAYS=12
```

The script calculates:

```text
2026-12-20 - 12 days
= 2026-12-08
```

State becomes:

```text
example.com|/path/to/cert.pem|2026-12-20|2026-12-08
```

The script will **not perform another SSL expiry check** until:

```text
2026-12-08
```

---

# 6. Daily cron is still recommended

The cron runs every day, but the script does not perform SSL checks for domains that are not due.

Recommended:

```cron
0 2 * * * /usr/local/bin/ssl-auto-renew.sh
```

Install with:

```bash
sudo crontab -e
```

This means:

```text
02:00 every day
       |
       +-- domain not due → do nothing
       |
       +-- domain due → live SSL check
                         |
                         +-- >12 days → update state
                         |
                         +-- <=12 days → Certbot renewal
```

This is intentional. The cron execution is cheap; SSL network checks happen only when required.

---

# 7. Example

Suppose there are five domains:

```text
domain-a.com   expires in 30 days
domain-b.com   expires in 20 days
domain-c.com   expires in 14 days
domain-d.com   expires in 12 days
domain-e.com   expires in 5 days
```

The script behaves approximately like:

```text
domain-a.com
    ↓
not due
    ↓
NO SSL check


domain-b.com
    ↓
not due
    ↓
NO SSL check


domain-c.com
    ↓
not due
    ↓
NO SSL check


domain-d.com
    ↓
threshold reached
    ↓
LIVE SSL CHECK
    ↓
12 days remaining
    ↓
CERTBOT RENEWAL


domain-e.com
    ↓
threshold already passed
    ↓
LIVE SSL CHECK
    ↓
5 days remaining
    ↓
CERTBOT RENEWAL
```

---

# 8. Renewal command

The script uses:

```bash
certbot --nginx -d mydomain.com --force-renewal
```

Certbot output is appended to:

```text
/var/log/ssl-auto-renew.log
```

---

# 9. Renewal failure behavior

If Certbot fails:

```text
ERROR: Certbot renewal FAILED for example.com
```

The state is deliberately **not moved into the future**.

Therefore the next cron run sees that the domain is still due and tries again.

Example:

```text
02:00 → renewal failed
next day 02:00 → retry
next day 02:00 → retry
```

This prevents a failed renewal from accidentally putting the certificate into a "not due" state.

---

# 10. State file

The state file is:

```text
/var/lib/ssl-auto-renew/state
```

Format:

```text
domain|certificate|expiry|next_check
```

Example:

```text
example.com|/etc/letsencrypt/live/example.com/fullchain.pem|2026-12-20|2026-12-08
api.example.com|/etc/letsencrypt/live/api.example.com/fullchain.pem|2027-01-15|2027-01-03
```

You can inspect it with:

```bash
sudo cat /var/lib/ssl-auto-renew/state
```

---

# 11. Logs

Main log:

```text
/var/log/ssl-auto-renew.log
```

Watch:

```bash
sudo tail -f /var/log/ssl-auto-renew.log
```

Find errors:

```bash
sudo grep -Ei 'ERROR|FAILED|WARNING' /var/log/ssl-auto-renew.log
```

Find renewals:

```bash
sudo grep -i 'renewal' /var/log/ssl-auto-renew.log
```

---

# 12. Nginx validation

After a successful renewal, the script runs:

```bash
nginx -t
```

If successful:

```bash
systemctl reload nginx
```

The script logs both operations.

---

# 13. Important behavior when a certificate is renewed externally

Suppose the script originally stores:

```text
expiry = 2026-10-20
next_check = 2026-10-08
```

But someone manually renews the certificate on:

```text
2026-10-01
```

When the script reaches the stored check date, it performs the live SSL check.

If the live certificate now expires much later, for example:

```text
2027-01-15
```

the script does **not** renew it again.

Instead, it updates the state:

```text
new expiry     = 2027-01-15
new next check = 2027-01-03
```

---

# 14. Important: Nginx configuration changes

If you add a completely new domain to Nginx, the next cron execution will discover it.

Because it has no state entry, the script performs the initial certificate check and creates its state.

If you remove a domain from Nginx, its old state entry remains in the state file. This is harmless, but it can be cleaned manually.

Example:

```bash
sudo sed -i '/old-domain.com/d' /var/lib/ssl-auto-renew/state
```

---

# 15. Manual forced test

Do not use `--force-renewal` manually against production unless you actually intend to issue a new certificate.

For testing discovery/state behavior:

```bash
sudo /usr/local/bin/ssl-auto-renew.sh
```

Check:

```bash
sudo cat /var/lib/ssl-auto-renew/state
```

---

# 16. Recommended deployment

```text
LB VM
│
├── Nginx
│   └── /etc/nginx/conf.d/*.conf
│
├── /usr/local/bin/
│   └── ssl-auto-renew.sh
│
├── /var/lib/ssl-auto-renew/
│   └── state
│
├── /var/log/
│   └── ssl-auto-renew.log
│
└── Cron
    └── 02:00 every day
```

The important design principle is:

```text
Cron frequency != SSL check frequency
```

Cron runs daily only to determine whether any domain has reached its stored check date. Actual SSL network checking happens only at the threshold.
