#!/usr/bin/env bash

Program="${0##*/}"

Err() {
	printf '%s\n' "$Program: $2" 1>&2
	(( $1 > 0 )) && exit $1
}

((UID)) && Err 1 'Needed to run as root user...'

[[ -f /lib/systemd/systemd ]] || Err 1 'Required systemd...'

read -p 'Enter your total amount of ram in GB: ' Amount

[[ $Amount =~ ^[1-9]+$ ]] || Err 1 'Only accept number...'

Amount=$(( $Amount * 2 ))

echo 'zram' > /etc/modules-load.d/zram.conf

echo 'options zram num_devices=1' > /etc/modprobe.d/zram.conf

Udev="KERNEL==\"zram0\", ATTR{comp_algorithm}=\"zstd\""
Udev+=", ATTR{disksize}=\"${Amount}G\""
Udev+=", RUN=\"/sbin/mkswap /dev/zram0\", TAG+=\"systemd\""

echo "$Udev" > /etc/udev/rules.d/99-zram.rules

echo '/dev/zram0 none swap pri=32767 0 0' >> /etc/fstab

while read; do
	printf '%s\n' "$REPLY"
done <<-EOF > /etc/sysctl.d/99-zram.conf
	# Zram devices
	vm.swappiness = 200
	vm.vfs_cache_pressure = 200
	vm.page-cluster = 0
EOF

printf '%s\n' "$Program: Now, add 'zswap.enabled=0' to your kernel parameter..."
