#!/usr/bin/env python3
import subprocess
import smtplib
import ssl
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from datetime import datetime, timezone
import os
import glob
import sys

ALERT_EMAIL = "mehmedovic.seid@gmail.com"
SMTP_USER = "scoutservicespro@gmail.com"
SMTP_PASS = "xgii mgwl fswy siin"
SMTP_HOST = "smtp.gmail.com"
SMTP_PORT = 587

warnings = []
status_lines = []

# 1. Disk Space Check (Threshold: 85%)
try:
    df_output = subprocess.check_output(["df", "-h", "/"], text=True).strip().splitlines()
    if len(df_output) >= 2:
        parts = df_output[1].split()
        use_pct = int(parts[4].replace("%", ""))
        avail = parts[3]
        total = parts[1]
        status_lines.append(f"Disk: {use_pct}% used ({avail} free of {total})")
        if use_pct >= 85:
            warnings.append(f"⚠️ DISK ALERT: Disk usage is at {use_pct}% (Threshold: 85%, Available: {avail} of {total})")
except Exception as e:
    warnings.append(f"Failed to check disk: {e}")

# 2. SSL Certificates Expiry Check (Threshold: <= 15 days)
try:
    cert_files = glob.glob("/var/www/proxy/certbot/etc/live/*/fullchain.pem")
    for cert in cert_files:
        domain = os.path.basename(os.path.dirname(cert))
        enddate_output = subprocess.check_output(
            ["openssl", "x509", "-enddate", "-noout", "-in", cert],
            text=True
        ).strip()
        date_str = enddate_output.replace("notAfter=", "").strip()
        expiry_date = datetime.strptime(date_str, "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
        days_left = (expiry_date - datetime.now(timezone.utc)).days
        status_lines.append(f"SSL '{domain}': {days_left} days remaining")
        if days_left <= 15:
            warnings.append(f"⚠️ SSL ALERT: Certificate for '{domain}' expires in {days_left} days (Date: {date_str})")
except Exception as e:
    warnings.append(f"Failed to check SSL certs: {e}")

# 3. Database Backup Check (Threshold: > 36h old or < 1 MB)
try:
    backup_files = sorted(glob.glob("/var/www/scout/db/backups/Scout2DB-AB-*.sql*"), key=os.path.getmtime, reverse=True)
    if not backup_files:
        warnings.append("⚠️ BACKUP ALERT: No backup files found in /var/www/scout/db/backups/")
    else:
        latest = backup_files[0]
        size_bytes = os.path.getsize(latest)
        size_mb = size_bytes / (1024 * 1024)
        mtime = datetime.fromtimestamp(os.path.getmtime(latest), tz=timezone.utc)
        hours_old = (datetime.now(timezone.utc) - mtime).total_seconds() / 3600
        status_lines.append(f"Latest Backup: {os.path.basename(latest)} ({size_mb:.1f} MB, {hours_old:.1f}h ago)")
        
        if size_bytes < 1024 * 1024:
            warnings.append(f"⚠️ BACKUP ALERT: Latest backup {os.path.basename(latest)} is empty/corrupted ({size_mb:.2f} MB)")
        if hours_old > 36:
            warnings.append(f"⚠️ BACKUP ALERT: No new backup in the last {hours_old:.1f} hours (> 36h)")
except Exception as e:
    warnings.append(f"Failed to check backups: {e}")

# Send Email ONLY if there are warnings (or if forced via --test)
send_test = "--test" in sys.argv

if warnings or send_test:
    subject = "[ALERT] Server Health Warning - 159.65.123.140" if warnings else "[TEST] Server Health Monitor Test - 159.65.123.140"
    
    body = f"Server Health Report - {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n"
    body += f"Host: 159.65.123.140\n\n"
    
    if warnings:
        body += "=== CRITICAL ISSUES DETECTED ===\n" + "\n".join(warnings) + "\n\n"
    else:
        body += "=== ALL MONITORED SYSTEMS OK (TEST EMAIL) ===\n\n"
        
    body += "=== SYSTEM DETAILS ===\n" + "\n".join(status_lines) + "\n"
    
    msg = MIMEMultipart()
    msg["From"] = f"Server Monitor <{SMTP_USER}>"
    msg["To"] = ALERT_EMAIL
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain"))
    
    try:
        context = ssl.create_default_context()
        with smtplib.SMTP(SMTP_HOST, SMTP_PORT) as server:
            server.starttls(context=context)
            server.login(SMTP_USER, SMTP_PASS)
            server.sendmail(SMTP_USER, ALERT_EMAIL, msg.as_string())
        print(f"Alert email sent successfully to {ALERT_EMAIL}")
    except Exception as e:
        print(f"Failed to send email: {e}")
else:
    print("All checks OK (Disk < 85%, Backups OK, SSL OK). No email sent.")
