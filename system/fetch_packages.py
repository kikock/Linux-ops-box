import urllib.request
import re
import os
import sys
import html

BASE_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), "packages"))
DEB_DIR = os.path.join(BASE_DIR, "deb")
RPM_DIR = os.path.join(BASE_DIR, "rpm")

os.makedirs(DEB_DIR, exist_ok=True)
os.makedirs(RPM_DIR, exist_ok=True)

# 1. Debian/Ubuntu (APT .deb) 软件源池配置
DEB_MAPPINGS = [
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

# 2. CentOS / RHEL (RPM .rpm) 软件源池配置
RPM_MAPPINGS = [
    ("curl", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"curl-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("openssl", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"openssl-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("lsof", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"lsof-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("tar", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"tar-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("wget", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"wget-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("cronie", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"cronie-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("bind-utils", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"bind-utils-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("nano", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"nano-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("net-tools", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"net-tools-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("unzip", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"unzip-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("zip", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"zip-[0-9][^\"<>]*(?:x86_64)\.rpm"),
    ("socat", "http://mirrors.aliyun.com/centos/7/os/x86_64/Packages/", r"socat-[0-9][^\"<>]*(?:x86_64)\.rpm"),
]

def download_pool(mappings, target_dir, label):
    print(f"\n[{label}] 开始处理离线安装包 (目录: {target_dir}) ...")
    for name, base_url, pattern in mappings:
        try:
            print(f"  -> 检索 {name} ...", end=" ", flush=True)
            req = urllib.request.Request(base_url, headers={"User-Agent": "Mozilla/5.0"})
            with urllib.request.urlopen(req, timeout=10) as resp:
                html_text = resp.read().decode("utf-8", errors="ignore")

            matches = list(set(re.findall(pattern, html_text)))
            if not matches:
                print("[未匹配到包]")
                continue

            target_file = html.unescape(sorted(matches)[-1])
            dl_url = base_url.rstrip("/") + "/" + target_file
            save_path = os.path.join(target_dir, target_file)

            if os.path.exists(save_path) and os.path.getsize(save_path) > 0:
                print(f"[已存在] {target_file}")
                continue

            print(f"下载 {target_file} ...", end=" ", flush=True)
            urllib.request.urlretrieve(dl_url, save_path)
            size_kb = os.path.getsize(save_path) / 1024
            print(f"[完成, {size_kb:.1f} KB]")

        except Exception as e:
            print(f"[错误: {e}]")

# 执行 DEB 和 RPM 分类下载
download_pool(DEB_MAPPINGS, DEB_DIR, "Debian/Ubuntu (.deb)")
download_pool(RPM_MAPPINGS, RPM_DIR, "CentOS/RHEL/Rocky/Euler (.rpm)")

print("\n" + "="*55)
print("离线包分类结构统计:")
for cat_name, c_dir in [("Debian/Ubuntu (deb)", DEB_DIR), ("CentOS/RHEL (rpm)", RPM_DIR)]:
    files = [f for f in os.listdir(c_dir) if os.path.isfile(os.path.join(c_dir, f))]
    print(f" [{cat_name}] ({len(files)} 个文件):")
    for f in sorted(files):
        fpath = os.path.join(c_dir, f)
        print(f"   - {f} ({os.path.getsize(fpath)/1024:.1f} KB)")
print("="*55)
