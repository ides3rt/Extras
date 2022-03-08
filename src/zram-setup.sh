#!/usr/bin/env bash

Program="${0##*/}"

Err() {
	printf '%s\n' "$Program: $2" 1>&2
	(( $1 > 0 )) && exit $1
}

(( $# > 0 )) && Err 2 "not required argument..."

((UID)) && Err 2 'needed to run as root user...'

if systemctl status systemd-udevd &>/dev/null; then
	Err 1 'required systemd(1) and udev(7)...'
fi

read F1 Mem _ < /proc/meminfo

Mem=$(( ( $Mem / 1024 / 1024 + 1 ) * 2 ))

echo 'zram' > /etc/modules-load.d/zram.conf

echo 'options zram num_devices=1' > /etc/modprobe.d/99-zram.conf

Udev='KERNEL=="zram0", ATTR{comp_algorithm}="zstd"'
Udev+=", ATTR{disksize}=\"${Mem}G\""
Udev+=', RUN="/sbin/mkswap /dev/zram0", TAG+="systemd"'

echo "$Udev" > /etc/udev/rules.d/99-zram.rules

echo '/dev/zram0 none swap pri=32767 0 0' >> /etc/fstab

read -d '' <<-EOF > /etc/sysctl.d/99-zram.conf
	vm.swappiness = 200
	vm.vfs_cache_pressure = 200
	vm.page-cluster = 0
EOF

printf '%s' "$REPLY"

printf '%s\n' "$Program: now, add 'zswap.enabled=0' to your kernel parameter..."
