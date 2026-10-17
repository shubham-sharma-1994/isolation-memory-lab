#!/usr/bin/env bash
# Download the pieces for the memory comparison (run as root inside WSL). Idempotent.
set -u
W=/root/memlab; mkdir -p $W; cd $W
say() { echo "[setup] $*"; }

say "packages (qemu, e2fsprogs, curl)"
apt-get update -qq >/dev/null 2>&1
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq qemu-system-x86 e2fsprogs >/dev/null 2>&1 && say "qemu: $(qemu-system-x86_64 --version | head -1)" || say "qemu install FAILED"

say "alpine minirootfs"
if ! ls alpine-minirootfs-*.tar.gz >/dev/null 2>&1; then
  base=https://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/x86_64
  f=$(curl -fsSL $base/ | grep -oE 'alpine-minirootfs-[0-9.]+-x86_64\.tar\.gz' | sort -V | tail -1)
  curl -fsSLO $base/$f && say "got $f" || say "alpine download FAILED"
fi

say "firecracker"
if [ ! -x firecracker ]; then
  tag=$(basename "$(curl -fsSLI -o /dev/null -w '%{url_effective}' https://github.com/firecracker-microvm/firecracker/releases/latest)")
  echo "$tag" > firecracker.tag
  curl -fsSL "https://github.com/firecracker-microvm/firecracker/releases/download/$tag/firecracker-$tag-x86_64.tgz" | tar xz
  cp release-$tag-x86_64/firecracker-$tag-x86_64 firecracker && chmod +x firecracker && say "firecracker $tag: $(./firecracker --version | head -1)" || say "firecracker FAILED"
fi

say "guest kernel (firecracker CI build)"
if [ ! -f vmlinux ]; then
  tag=$(cat firecracker.tag); CI=${tag%.*}
  key=$(curl -fsSL "http://spec.ccfc.min.s3.amazonaws.com/?prefix=firecracker-ci/$CI/x86_64/vmlinux-&list-type=2" | grep -oE "firecracker-ci/$CI/x86_64/vmlinux-[0-9]+\.[0-9]+\.[0-9]{1,3}" | sort -V | tail -1)
  say "kernel key: $key"
  curl -fsSL -o vmlinux "https://s3.amazonaws.com/spec.ccfc.min/$key" && say "kernel $(du -h vmlinux | cut -f1)" || say "kernel download FAILED"
fi

say "cloud hypervisor"
if [ ! -x cloud-hypervisor ]; then
  url=$(curl -fsSL https://api.github.com/repos/cloud-hypervisor/cloud-hypervisor/releases/latest | grep -oE '"browser_download_url": "[^"]*/cloud-hypervisor-static"' | head -1 | cut -d'"' -f4)
  say "url: $url"
  curl -fsSL -o cloud-hypervisor "$url" && chmod +x cloud-hypervisor && say "cloud-hypervisor: $(./cloud-hypervisor --version | head -1)" || say "cloud-hypervisor FAILED"
fi

say "alpine root filesystem image (ext4, 64 MB, prints BOOTED then idles)"
if [ ! -f alpine.ext4 ]; then
  rm -rf rootdir; mkdir rootdir; tar xzf alpine-minirootfs-*.tar.gz -C rootdir
  cat > rootdir/etc/inittab <<'EOT'
::sysinit:/bin/mount -t proc proc /proc
::sysinit:/bin/mount -t sysfs sys /sys
::sysinit:/bin/mount -t devtmpfs dev /dev
::once:/bin/echo MEMLAB-BOOTED
::respawn:/bin/sleep 100000
::ctrlaltdel:/sbin/reboot
EOT
  mkfs.ext4 -q -F -d rootdir alpine.ext4 64M && say "alpine.ext4 $(du -h alpine.ext4 | cut -f1)" || say "mkfs FAILED"
fi
say "done"; ls -la $W | cut -c1-90
