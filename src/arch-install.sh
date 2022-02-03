#!/usr/bin/env bash

# Detect CPU
while read VendorID; do
	[[ "$VendorID" == *vendor_id* ]] && break
done < /proc/cpuinfo
case "$VendorID" in
	*AMD*)
		CPU=amd ;;
	*Intel*)
		CPU=intel ;;
esac
unset -v VendorID

Preinstall() {
	# Load my keymaps
	URL=https://raw.githubusercontent.com/ides3rt/grammak/master/src/grammak-iso.map
	curl -O "$URL"; gzip "${URL##*/}"
	loadkeys "${URL##*/}".gz
	unset -v URL

	# Partition, format, and mount the drive
	PS3='Select your disk: '
	select Disk in $(lsblk -dno PATH); do
		[[ -z $Disk ]] && continue

		parted "$Disk" mklabel gpt
		sgdisk "$Disk" -n=1:0:+512M -t=1:ef00
		sgdisk "$Disk" -n=2:0:0

		[[ $Disk == *nvme* ]] && P=p
		mkfs.fat -F 32 -n EFI "$Disk$P"1
		mkfs.btrfs -f -L Arch "$Disk$P"2

		mount "$Disk$P"2 /mnt
		btrfs su cr @; btrfs su cr @home
		umount /mnt

		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@ "$Disk$P"2 /mnt
		mkdir -p /mnt/home
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,autodefrag,subvol=@home "$Disk$P"2 /mnt/home

		mkdir /mnt/boot
		mount -o nosuid,nodev,noexec,noatime,fmask=0177,dmask=0077 "$Disk$P"2 /mnt/boot

	done

	# Install base packages
	pacstrap /mnt base base-devel linux linux-firmware neovim "$CPU"-ucode

	# Generate FSTAB
	genfstab -U /mnt > /mnt/etc/fstab
	echo 'tmpfs /tmp tmpfs nosuid,nodev,noatime,size=6G 0 0' >> /mnt/etc/fstab
	echo 'tmpfs /dev/shm tmpfs nosuid,nodev,noexec,noatime,size=1G 0 0' >> /mnt/etc/fstab
	echo 'proc /proc proc nosuid,nodev,noexec,gid=proc,hidepid=2 0 0' >> /mnt/etc/fstab

	cp "$0" /mnt
	arch-chroot /mnt /"${0##*/}"
}

Postinstall() {
	# Set date and time
	printf '%s\n' "Date/time format is 'yyyy-mm-dd HH:nn:ss'..."
	read -p 'Enter your current date/time: ' Date
	hwclock --set --date="$Date"
	hwclock --hctosys
	unset -v Date

	# Set locale
	echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
	locale-gen
	echo 'LANG=en_US.UTF-8' > /etc/locale.conf

	# Hostname
	read -p 'Your hostname: ' Hostname
	echo "$Hostname" > /etc/hostname
	unset -v Hostname

	# Networking
	echo '127.0.0.1 localhost' >> /etc/hosts
	echo '::1 localhost' >> /etc/hosts
	systemctl enable systemd-networkd systemd-resolved

	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/systemd/network/20-dhcp.network
		[Match]
		Name=*

		[Network]
		DHCP=yes
		IPv6AcceptRA=true
		DNSOverTLS=yes
		DNSSEC=yes
		DNS=45.90.28.0#3579e8.dns1.nextdns.io
		DNS=2a07:a8c0::#3579e8.dns1.nextdns.io

		[DHCP]
		UseDNS=false

		[IPv6AcceptRA]
		UseDNS=false
	EOF

	# Install bootloader
	echo "ParallelDownloads = $(( $(nproc) + 1 ))" >> /etc/pacman.conf
	pacman -S --noconfirm efibootmgr dosfstools opendoas

	Disk=$(findmnt / -o SOURCE --noheadings)

	if [[ $Disk == *nvme* ]]; then
		Modules=nvme
		Disk="${Disk/p*/}"
	else
		Modules='ahci sd_mod'
		Disk="${Disk/[1-9]*/}"
	fi

	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/mkinitcpio.d/linux.preset
		# mkinitcpio preset file for the 'linux' package

		ALL_config="/etc/mkinitcpio.conf"
		ALL_kver="/boot/vmlinuz-linux"

		PRESETS=('default')

		default_image="/boot/initramfs-linux.img"

		fallback_image="/boot/initramfs-linux-fallback.img"
		fallback_options="-S autodetect"
	EOF

	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/mkinitcpio.conf
		MODULES=($Modules btrfs)
		BINARIES=()
		FILES=()
		HOOKS=(base modconf)
		COMPRESSION="lz4"
		COMMPRESSION_OPTIONS=(-12 --favor-decSpeed)
	EOF

	rm -f /boot/initramfs-linux-fallback.img
	mkinitcpio -P

	# Install Zram
	URL=https://raw.githubusercontent.com/ides3rt/extras/master/src/zram-setup.sh
	curl -O "$URL"; bash "${URL##*/}"
	unset -v URL

	# Install bootloader to UEFI
	System=$(findmnt / -o UUID --noheadings)
	efibootmgr --disk "$Disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\vmlinuz-linux' \
		--unicode "root=UUID=$System rootflags=subvolid=256 ro initrd=\\$CPU-ucode.img initrd=\\initramfs-linux.img quiet libahci.ignore_sss=1 zswap.enabled=0"
	unset -v System ESPPosition FSSys Disk Modules CPU

	PS3='Select your GPU [1-3]: '
	select GPU in xf86-video-amdgpu xf86-video-intel nvidia; do
		[[ -n $GPU ]] && break
	done

	# Install additional packages
	pacman -S dash nvidia linux-headers xorg-server xorg-xinit \
		xorg-xsetroot xorg-xrandr git wget man-db htop ufw bspwm man-pages \
		rxvt-unicode feh maim exfatprogs picom rofi pipewire mpv pigz \
		pacman-contrib arc-solid-gtk-theme papirus-icon-theme aria2 \
		terminus-font zip unzip p7zip pbzip2 rsync bc yt-dlp dunst \
		rustup sccache xdotool pwgen dbus-broker tmux links archiso \
		firefox-developer-edition sxhkd xclip perl-image-exiftool
	pacman -S --asdeps qemu edk2-ovmf memcached libnotify pipewire-pulse \
		bash-completion
	unset -v GPU

	# Configuration 1
	ufw enable
	systemctl disable dbus
	systemctl enable dbus-broker fstrim.timer avahi-daemon ufw
	systemctl --global enable dbus-broker pipewire-pulse
	ln -sf bin /usr/local/sbin
	ln -sf /usr/share/fontconfig/conf.avail/10-hinting-slight.conf /etc/fonts/conf.d/
	ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/
	ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/

	# Configuration 2
	ln -sfT dash /bin/sh
	groupadd -r doas; groupadd -r fstab
	echo 'permit nolog :doas' > /etc/doas.conf
	chmod 640 /etc/doas.conf /etc/fstab
	chown :doas /etc/doas.conf; chown :fstab /etc/fstab
	sed -i '/required/s/#//' /etc/pam.d/su
	sed -i '/required/s/#//' /etc/pam.d/su-l

	# Define groups
	Groups='proc,games,dbus,scanner,fstab,doas,users'
	Groups+=',video,render,lp,kvm,input,audio,wheel'

	# Create user
	while :; do
		read -p 'Your username: ' Username
		useradd -mG "$Groups" "$Username"
		passwd "$Username" && break
	done
	unset -v Groups

	# Download my keymaps
	URL=https://raw.githubusercontent.com/ides3rt/grammak/master/installer.sh
	curl -O "$URL"; bash "${URL##*/}"
	unset -v URL

	# My keymap
	File=/etc/vconsole.conf
	echo 'KEYMAP=grammak-iso' > "$File"
	echo 'FONT=ter-118b' >> "$File"
	unset -v File
}

read Root _ <<< "$(ls -di /)"
read Init _ <<< "$(ls -di /proc/1/root/.)"

if (( Root == Init )); then
	Preinstall
else
	Postinstall
fi
