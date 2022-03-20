#!/usr/bin/env bash

progrm=${0##*/}

panic() {
	printf '%s\n' "$progrm: $2" 1>&2
	(( $1 > 0 )) && exit $1
}

(( $# > 0 )) && panic 2 "needn't argument..."

((UID)) && panic 2 'required root privileges...'

if ! [[ -f /lib/systemd/systemd && -f /lib/systemd/systemd-udevd ]]; then
	panic 1 'dependencies, `systemd` and `udev`, not found...'
fi

read _ mem _ < /proc/meminfo

mem=$(( ( $mem / 1024 / 1024 + 1 ) * 2 ))

echo 'zram' > /etc/modules-load.d/zram.conf

echo 'options zram num_devices=1' > /etc/modprobe.d/99-zram.conf

udev='KERNEL=="zram0", ATTR{comp_algorithm}="zstd"'
udev+=", ATTR{disksize}=\"${mem}G\""
udev+=', RUN="/sbin/mkswap /dev/zram0", TAG+="systemd"'

echo "$udev" > /etc/udev/rules.d/99-zram.rules

echo '/dev/zram0 none swap pri=32767 0 0' >> /etc/fstab

read -d '' <<-EOF
	vm.swappiness = 200
	vm.vfs_cache_pressure = 200
	vm.page-cluster = 0
EOF

printf '%s' "$REPLY" > /etc/sysctl.d/99-zram.conf

printf '%s\n' "$Program: now, add 'zswap.enabled=0' to your kernel parameter..."
