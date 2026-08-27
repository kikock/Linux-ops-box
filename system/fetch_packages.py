import urllib.request
import re
import os
import sys

TARGET_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "packages"))
os.makedirs(TARGET_DIR, exist_ok=True)

import html

# 目标基础组件与镜像源目录映射
POOL_MAPPINGS = [
    ("socat", "http://mirrors.aliyun.com/ubuntu/pool/main/s/socat/", r"socat_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("lsof", "http://mirrors.aliyun.com/ubuntu/pool/main/l/lsof/", r"lsof_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("nano", "http://mirrors.aliyun.com/ubuntu/pool/main/n/nano/", r"nano_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("cron", "http://mirrors.aliyun.com/ubuntu/pool/main/c/cron/", r"cron_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("htop", "http://mirrors.aliyun.com/ubuntu/pool/main/h/htop/", r"htop_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("net-tools", "http://mirrors.aliyun.com/ubuntu/pool/main/n/net-tools/", r"net-tools_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("unzip", "http://mirrors.aliyun.com/ubuntu/pool/main/u/unzip/", r"unzip_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("zip", "http://mirrors.aliyun.com/ubuntu/pool/main/z/zip/", r"zip_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("curl", "http://mirrors.aliyun.com/ubuntu/pool/main/c/curl/", r"curl_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("wget", "http://mirrors.aliyun.com/ubuntu/pool/main/w/wget/", r"wget_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("tar", "http://mirrors.aliyun.com/ubuntu/pool/main/t/tar/", r"tar_[0-9][^\"<>]*(?:amd64)\.deb"),
    ("openssl", "http://mirrors.aliyun.com/ubuntu/pool/main/o/openssl/", r"openssl_[0-9][^\"<>]*(?:amd64)\.deb"),
]

print(f"Preparing to download packages to: {TARGET_DIR} ...")

for name, base_url, pattern in POOL_MAPPINGS:
    try:
        print(f"-> Searching {name} ...", end=" ", flush=True)
        req = urllib.request.Request(base_url, headers={"User-Agent": "Mozilla/5.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:
            html_text = resp.read().decode("utf-8", errors="ignore")
        
        matches = list(set(re.findall(pattern, html_text)))
        if not matches:
            print("[Not found]")
            continue
        
        # 挑选适用于 amd64 的稳定版本
        target_file = html.unescape(sorted(matches)[-1])
        dl_url = base_url.rstrip("/") + "/" + target_file
        save_path = os.path.join(TARGET_DIR, target_file)

        if os.path.exists(save_path) and os.path.getsize(save_path) > 0:
            print(f"[Already exists] {target_file}")
            continue

        print(f"Downloading {target_file} ...", end=" ", flush=True)
        urllib.request.urlretrieve(dl_url, save_path)
        size_kb = os.path.getsize(save_path) / 1024
        print(f"[Done, {size_kb:.1f} KB]")

    except Exception as e:
        print(f"[Error: {e}]")

print(f"\nAll downloads completed! Current packages in {TARGET_DIR}:")
for f in os.listdir(TARGET_DIR):
    fpath = os.path.join(TARGET_DIR, f)
    print(f" - {f} ({os.path.getsize(fpath)/1024:.1f} KB)")
