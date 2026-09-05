# Deploy the archive to an Ubuntu VPS

These instructions assume an Ubuntu VPS with sudo access and a domain you control.
Replace `YOUR_USER`, `YOUR_VPS_IP`, and `archive.example.com` with your details.
The server serves static HTML; it does not need Haskell or the source reading pack.

## 1. Upload from your Mac

From this repository's root:

```sh
scp dist/collusion-site.tar.gz dist/collusion-site.tar.gz.sha256 YOUR_USER@YOUR_VPS_IP:~/
ssh YOUR_USER@YOUR_VPS_IP
```

For a custom SSH port, use `scp -P PORT` and `ssh -p PORT`.

## 2. Point DNS and allow web traffic

Create an A record for `archive.example.com` pointing to the VPS IPv4 address.
Only add an AAAA record if IPv6 is configured and reachable on that VPS.
Allow incoming TCP ports 80 and 443 in your VPS provider's firewall and any
host firewall, keeping your SSH port allowed. Leave port 80 open for redirects
and certificate renewal. If UFW is already active, after installing Nginx below:

```sh
sudo ufw allow 'Nginx Full'
```

## 3. Install Nginx and extract the site (on the VPS)

Use `/var/www/collusion-report` exclusively for this archive.

```sh
sudo apt update
sudo apt install -y nginx snapd
cd ~
sha256sum -c collusion-site.tar.gz.sha256
sudo install -d -m 755 /var/www/collusion-report
sudo tar --no-same-owner -xzf collusion-site.tar.gz -C /var/www/collusion-report
sudo chown -R root:root /var/www/collusion-report
sudo find /var/www/collusion-report -type d -exec chmod 755 {} +
sudo find /var/www/collusion-report -type f -exec chmod 644 {} +
```

The archive contains `index.html`, `groups/`, and `fragments/` directly, with
no extra `_site` directory. Check that the checksum reports `OK` before extracting.

## 4. Configure Nginx

Create a new configuration for this domain; if the domain already has a server
block, edit that block instead of creating a duplicate. Replace the domain in
this snippet before running it. The quoted `EOF_NGINX` delimiter preserves `$uri`.

```sh
sudo tee /etc/nginx/sites-available/collusion-report > /dev/null <<'EOF_NGINX'
server {
    listen 80;
    listen [::]:80;
    server_name archive.example.com;

    root /var/www/collusion-report;
    index index.html;
    charset utf-8;

    location / {
        try_files $uri $uri/ =404;
    }
}
EOF_NGINX
sudo ln -s /etc/nginx/sites-available/collusion-report /etc/nginx/sites-enabled/collusion-report
sudo nginx -t && sudo systemctl enable --now nginx && sudo systemctl reload nginx
```

Skip `ln -s` if that symlink already exists. Open `http://archive.example.com`
and confirm your homepage loads before requesting a certificate.

This follows Nginx's [static content configuration](https://docs.nginx.com/nginx/admin-guide/web-server/serving-static-content/).

## 5. Enable HTTPS with Let's Encrypt

For a fresh Certbot installation:

```sh
sudo snap install --classic certbot
sudo /snap/bin/certbot --nginx --redirect -d archive.example.com
sudo /snap/bin/certbot renew --dry-run
```

Follow the email and terms prompts. Certbot obtains the certificate, updates
Nginx for HTTPS, and redirects HTTP to HTTPS. The snap schedules automatic
renewal; the dry run checks that renewal works. If Certbot is already installed
through another package manager, use that existing installation or follow the
official migration instructions rather than mixing installations.

Open `https://archive.example.com` and check a group and a fragment page.
For another hostname such as `www`, configure its DNS and add it to
`server_name` and as another `-d` argument before requesting the certificate.

See the official [Certbot Nginx instructions](https://certbot.eff.org/instructions?os=snap&ws=nginx).

## Later updates

Rebuild and create a new tarball locally, then upload it again. Extracting over
an existing directory replaces matching files but leaves obsolete files behind.
For an exact replacement, extract into a fresh release directory and change the
Nginx `root` to that directory, then run `sudo nginx -t` and reload Nginx. Keep
the previous release until the new one is verified.

## Git

Generated HTML under `collusion-report/_site/`, the Hakyll cache under
`collusion-report/_cache/`, and tarballs under `dist/` are ignored by `.gitignore`.
The authored `index.html` and HTML templates are source files and remain tracked.
