# Containerized Postfix SMTP Relay for Microsoft 365

A lightweight, containerized Postfix SMTP relay that authenticates to Microsoft 365 using a TLS certificate via an Exchange Online inbound connector. Certificates are issued and renewed via Certbot using the Cloudflare DNS-01 challenge.

## Stack

- **Base image:** Alpine 3.19
- **Certificate management:** Certbot (`certbot/dns-cloudflare`)
- **Relay target:** Microsoft 365 Exchange Online
- **Container management:** Docker Compose

## Why Alpine

Ubuntu and Debian-based Postfix images run the outbound `smtp` process in a chroot jail, which prevents DNS resolution inside containers. Alpine avoids this entirely with one targeted `master.cf` change — see [the chroot note](#important-mastercf-change) below.

## Prerequisites

- Linux VPS with Docker and Docker Compose
- Outbound port 25 unblocked by your VPS provider (many block this by default — submit a support ticket)
- Domain managed in Cloudflare DNS
- Cloudflare API token with DNS edit permissions for the target zone
- A record for your relay hostname pointing to the VPS public IP (DNS only, no proxy)
- One or more accepted domains configured in Microsoft 365

## Project Structure

```
smtp-relay/
├── docker-compose.yml
├── Dockerfile
├── Dockerfile.v1              # Ubuntu-based version (reference only — has chroot DNS issues)
├── entrypoint.sh
├── cloudflare.ini             # NOT committed — contains API token
├── cloudflare.ini.example     # Template — copy and fill in your token
└── config/
    ├── main.cf
    ├── master.cf
    ├── mynetworks
    ├── transport
    ├── tls_policy
    └── header_checks
```

## Quick Start

**1. Clone the repo**

```bash
git clone https://github.com/jevellangelo/smtp-relay.git
cd smtp-relay
```

**2. Create your Cloudflare credentials file**

```bash
cp cloudflare.ini.example cloudflare.ini
# Edit cloudflare.ini and add your Cloudflare API token
chmod 600 cloudflare.ini
```

**3. Update configuration for your environment**

Edit the following files replacing placeholder values:

| File | What to change |
|---|---|
| `docker-compose.yml` | Email address, relay hostname |
| `config/main.cf` | `myhostname`, cert paths |
| `config/transport` | Your M365 domain(s) and MX endpoints |
| `config/tls_policy` | Your M365 MX endpoints |
| `config/header_checks` | Your relay hostname |
| `config/mynetworks` | Your trusted sender IPs |
| `Dockerfile` | Mailname (your primary domain) |

**4. Deploy**

```bash
docker compose up --build -d
```

On first run, Certbot issues the certificate then exits. Postfix starts once Certbot completes. On subsequent runs Certbot exits immediately (cert already exists).

**5. Test**

From a machine whose IP is in `mynetworks`:

```bash
openssl s_client -connect relay.yourdomain.com:587 -starttls smtp
```

## Configuration Notes

### config/mynetworks

Controls which source IPs can relay through Postfix. Uses CIDR format with `OK`:

```
203.0.113.10/32 OK    # office/home public IP
198.51.100.5/32 OK    # other trusted host
```

### config/transport

Routes mail to the correct M365 MX endpoint per domain. Dots in domain names become dashes in the `.mail.protection.outlook.com` hostname:

```
yourdomain.com :[yourdomain-com.mail.protection.outlook.com]:25
domain2.com    :[domain2-com.mail.protection.outlook.com]:25
*              :[yourdomain-com.mail.protection.outlook.com]:25
```

Uses `texthash:` map type on Alpine — no `postmap` required.

### config/header_checks

Prepends headers that tell Exchange Online to treat relayed mail as internal. Required for mail to land in the inbox rather than junk for internal recipients:

```
/^To:/i PREPEND X-MS-Exchange-CrossPremises-AuthAs: Internal
/^From:/i PREPEND X-MS-Exchange-CrossPremises-AuthSource: relay.yourdomain.com
```

### Important master.cf Change

The outbound `smtp` unix service **must** have chroot disabled (`n`):

```
smtp      unix  -       -       n       -       -       smtp
```

Without this, the smtp process runs chrooted and cannot access `/etc/resolv.conf`, causing all outbound DNS resolution to fail silently.

## Microsoft 365 Setup

### Inbound Connector

1. Exchange Admin Center → **Mail flow > Connectors** → Add a connector
2. From: **Your organization's email server** → To: **Office 365**
3. Name it (e.g. `relay.yourdomain.com`)
4. Identify by: **certificate** — enter your relay FQDN as the subject name to match
5. Enable and save

### Transport Rules for External Recipients

The `header_checks` file injects internal headers on all messages. Without these rules, mail to external addresses (outside your M365 tenant) will be rejected by Exchange.

Create via Exchange Online PowerShell:

```powershell
Connect-ExchangeOnline -UserPrincipalName admin@yourdomain.com -Device

New-TransportRule -Name "Strip AuthAs Header for External Recipients" `
    -SentToScope "NotInOrganization" `
    -RemoveHeader "X-MS-Exchange-CrossPremises-AuthAs"

New-TransportRule -Name "Strip AuthSource Header for External Recipients" `
    -SentToScope "NotInOrganization" `
    -RemoveHeader "X-MS-Exchange-CrossPremises-AuthSource"
```

> The Exchange Admin Center GUI only allows one "Remove a header" action per rule — PowerShell is required to create both in separate rules.

### Accepted Domains for Subdomains

If your applications send from a subdomain (e.g. `noreply@app.yourdomain.com`), add it as an **Internal relay** domain in Exchange Admin Center → Settings → Domains. Without this, M365 will reject mail from unrecognized sender domains.

## SPF Records

Add your VPS public IP to the SPF record for each sending domain:

```
v=spf1 ip4:<your-vps-ip> include:spf.protection.outlook.com ~all
```

## Certificate Renewal

Certbot certificates expire after 90 days. Add a cron job on the host:

```bash
crontab -e
```

```
0 12 * * * cd /path/to/smtp-relay && docker compose run --rm certbot renew && docker compose exec postfix postfix reload
```

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| `Host or domain name not found type=AAAA` | Outbound smtp process is chrooted | Set `smtp unix - - n` in `master.cf` |
| `554 5.7.1 Relay access denied` | Source IP not in mynetworks | Add IP to `config/mynetworks`, rebuild |
| `unsupported dictionary type: hash` | Alpine has no postfix-hash package | Use `texthash:` instead of `hash:` in `main.cf` |
| `open database /etc/postfix/aliases.lmdb` | Alpine defaults to lmdb for aliases | Set `alias_maps =` and `alias_database =` to empty in `main.cf` |
| `exec /entrypoint.sh: no such file or directory` | CRLF line endings in `entrypoint.sh` | Recreate with heredoc: `cat > entrypoint.sh << 'EOF'` |
| Connection refused on port 587 | Submission port not enabled | Uncomment `submission inet` in `master.cf` |
| `451 4.4.4 Mail received as unauthenticated` | Sender domain not accepted in M365 | Add subdomain as Internal relay domain in Exchange |
| `451 4.4.62 Mail sent to the wrong Office 365 region` | Personal outlook.com/hotmail.com routed to business endpoint | Add explicit `texthash:` transport entries for those domains |
| External recipients not receiving mail | Internal headers not stripped | Create Exchange transport rules (see above) |

## License

MIT
