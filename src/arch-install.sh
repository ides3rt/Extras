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

sed -i '/RemoteFileSigLevel/s/#//' /etc/pacman.conf
sed -i "s/#ParallelDownloads = 5/ParallelDownloads = $(( $(nproc) + 1 ))/" /etc/pacman.conf

read Root _ <<< "$(ls -di /)"
read Init _ <<< "$(ls -di /proc/1/root/.)"

if (( Root == Init )); then

	# Load my keymap
	URL=https://raw.githubusercontent.com/ides3rt/grammak/master/src/grammak-iso.map
	curl -O "$URL"; gzip "${URL##*/}"
	loadkeys "${URL##*/}".gz 2>/dev/null
	unset -v URL

	# Partition, format, and mount the drive
	PS3='Select your disk: '
	select Disk in $(lsblk -dno PATH); do
		[[ -z $Disk ]] && continue

		parted "$Disk" mklabel gpt
		sgdisk "$Disk" -n=1:0:+1024M -t=1:ef00
		sgdisk "$Disk" -n=2:0:0

		[[ $Disk == *nvme* ]] && P=p
		mkfs.fat -F 32 -n EFI "$Disk$P"1
		mkfs.btrfs -f -L Arch "$Disk$P"2

		mount "$Disk$P"2 /mnt
		btrfs su cr /mnt/@

		mkdir /mnt/@/usr
		btrfs su cr /mnt/@/usr/local

		mkdir -p /mnt/@/var/lib/libvirt
		btrfs su cr /mnt/@/var/cache
		btrfs su cr /mnt/@/var/lib/libvirt/images
		btrfs su cr /mnt/@/var/local
		btrfs su cr /mnt/@/var/log
		btrfs su cr /mnt/@/var/opt
		btrfs su cr /mnt/@/var/spool
		btrfs su cr /mnt/@/var/tmp

		btrfs su cr /mnt/@/.snapshots
		mkdir /mnt/@/.snapshots/1
		btrfs su cr /mnt/@/.snapshots/1/snapshot
		btrfs su set-default /mnt/@/.snapshots/1/snapshot

		umount /mnt
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async "$Disk$P"2 /mnt

		mkdir -p /mnt/{boot,usr/local,var/cache,var/local,var/log,var/opt,var/spool,var/tmp,.snapshots}
		chmod 700 /mnt/boot

		mkdir -p /mnt/var/lib/{libvirt/images,machines,portables}
		chmod 700 /mnt/var/lib/{machines,portables}

		mount -o nosuid,nodev,noexec,noatime,fmask=0177,dmask=0077 "$Disk$P"1 /mnt/boot
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/usr/local "$Disk$P"2 /mnt/usr/local
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/cache "$Disk$P"2 /mnt/var/cache
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/lib/libvirt/images "$Disk$P"2 /mnt/var/lib/libvirt/images
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/local "$Disk$P"2 /mnt/var/local
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/log "$Disk$P"2 /mnt/var/log
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/opt "$Disk$P"2 /mnt/var/opt
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/spool "$Disk$P"2 /mnt/var/spool
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/tmp "$Disk$P"2 /mnt/var/tmp
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/.snapshots "$Disk$P"2 /mnt/.snapshots

		break
	done

	# Install base packages
	pacstrap /mnt base base-devel linux-hardened linux-hardened-headers linux-firmware neovim "$CPU"-ucode

	# Symlink some directories
	mkdir -p /mnt/var/local/{home,opt,root,srv/http,srv/ftp}
	rm -r /mnt/{home,opt,root,srv}
	ln -s var/local/home var/local/opt var/local/root var/local/srv /mnt

	# Generate FSTAB
	genfstab -U /mnt >> /mnt/etc/fstab

	# Clean up FSTAB
	sed -i 's/,subvol=\/@\/\.snapshots\/1\/snapshot//' /mnt/etc/fstab
	sed -i 's/,subvolid=[[:digit:]]*//; s/\/@/@/; s/rw,//; s/,ssd//' /mnt/etc/fstab

	# Optimize FSTAB
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF >> /mnt/etc/fstab
		tmpfs /tmp tmpfs nosuid,nodev,noatime,size=6G 0 0

		tmpfs /dev/shm tmpfs nosuid,nodev,noexec,noatime,size=1G 0 0

		proc /proc proc nosuid,nodev,noexec,gid=proc,hidepid=2 0 0

	EOF

	# Copy installer script to Chroot
	cp ./"$0" /mnt
	arch-chroot /mnt bash "${0##*/}"

	# Clean up
	rm -rf /mnt/{grammak,"${0##*/}",installer.sh,zram-setup.sh}
	umount -R /mnt

else

	# Set date and time
	while :; do
		read -p 'Your timezone: ' Timezone
		[[ -f /usr/share/zoneinfo/$Timezone ]] && break
		printf '%s\n' "Err: '$Timezone' doesn't exists..." 1>&2
	done

	ln -sf /usr/share/zoneinfo/"$Timezone" /etc/localtime
	hwclock --systohc

	# Set locale
	echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
	locale-gen
	echo 'LANG=en_US.UTF-8' > /etc/locale.conf

	# Hostname
	read -p 'Your hostname: ' Hostname
	echo "$Hostname" > /etc/hostname
	unset -v Hostname

	# Networking
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF >> /etc/hosts

		127.0.0.1 localhost
		::1 localhost
	EOF
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

	Disk=$(findmnt / -o SOURCE --noheadings)

	if [[ $Disk == *nvme* ]]; then
		Modules='nvme nvme_core'
		Disk="${Disk/p*/}"
	else
		Modules='ahci sd_mod'
		Disk="${Disk/[1-9]*/}"
	fi

	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/mkinitcpio.d/linux-hardened.preset
		# mkinitcpio preset file for the 'linux-hardened' package

		ALL_config="/etc/mkinitcpio.conf"
		ALL_kver="/boot/vmlinuz-linux-hardened"

		PRESETS=('default')

		default_image="/boot/initramfs-linux-hardened.img"

		fallback_image="/boot/initramfs-linux-hardened-fallback.img"
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

	rm -f /boot/initramfs-linux-hardened-fallback.img

	AddsPkgs=(
		btrfs-progs # BTRFS support
		efibootmgr # UEFI manager
		dosfstools # Fat and it's derivative support
		opendoas # Privileges elevator
		ufw # Firewall
		apparmor # Applications sandbox
		man-db # An interface to system manuals
		man-pages # Linux manuals
		dash # Faster sh(1)
		dbus-broker # Better dbus(1)
	)

	# Install additional packages
	pacman -S --noconfirm "${AddPkgs[@]}"
	unset AddsPkgs

	# Find rootfs UUID
	System=$(findmnt / -o UUID --noheadings)

	# Required Kernel Parameter
	Kernel="root=UUID=$System ro initrd=\\$CPU-ucode.img"
	Kernel+=' initrd=\initramfs-linux-hardened.img'

	# Speed improvement
	Kernel+=' quiet libahci.ignore_sss=1 zswap.enabled=0'

	# Enable apparmor
	Kernel+=' lsm=landlock,lockdown,yama,apparmor,bpf'

	# Install bootloader to UEFI
	efibootmgr --disk "$Disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\vmlinuz-linux-hardened' \
		--unicode "$Kernel"
	unset -v System Disk Modules CPU Kernel

	# Select GPU
	PS3='Select your GPU [1-3]: '
	select GPU in xf86-video-amdgpu xf86-video-intel nvidia-dkms; do
		[[ -n $GPU ]] && break
	done

	OptsPkgs=(
		git wget rsync # Downloading tools
		htop # System monitor
		tmux # Terminal multiplexer
		zip unzip # Additional compression algorithms
		pigz p7zip pbzip2 # Faster compression
		rustup sccache # Rust development
		bc # Linux kernel make deps
		archiso # Create Arch iso
		udisks2 # Mount drive via polkit(8)
		exfatprogs # ExFat support
		pacman-contrib # pacman(8) essentials
		terminus-font # Better TTY font
		pwgen # Password generator
		xorg-server xorg-xrandr # Xorg
		xorg-xinit # Display manager
		arc-solid-gtk-theme papirus-icon-theme # GTK themes
		bspwm sxhkd xorg-xsetroot # bspwm(1) essentials
		rxvt-unicode # Terminal Emulater
		rofi # Programs launcher
		pipewire # Sound server
		dunst # Nofication daemon
		picom # Compositer
		feh # Wallpaper/Image viewer
		maim xdotool # Screenshot tools
		perl-image-exiftool # Image's metadata tools
		firefox-developer-edition links # Browsers
		mpv # Media player
	)

	OptsDeps=(
		bash-completion # Better completion in Bash
		memcached # Cache support in Rust
		libnotify # Send notification
		pipewire-pulse # Pulseaudio support in Pipewire
		realtime-privileges rtkit # Realtime support in Pipewire
		yt-dlp # Stream YT into mpv(1) support
		aria2 # Faster yt-dlp(1)
		xclip # X-server clipboard in support nvim(1)
	)

	# Install "optional" packages
	pacman -S "$GPU" "${OptsPkgs[@]}"

	if (( $? == 0 )); then
		# Install optional deps
		pacman -S --asdeps --noconfirm "${OptsDeps[@]}"

		# Config "optional" packages
		systemctl --global enable pipewire-pulse
		sed -i '/encryption/s/luks1/luks2/' /etc/udisks2/udisks2.conf
		ln -s run/media /
		ln -sf /usr/share/fontconfig/conf.avail/10-hinting-slight.conf /etc/fonts/conf.d
		ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d
		ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d
	fi

	unset OptsPkgs OptsDeps

	# Install Zram
	URL=https://raw.githubusercontent.com/ides3rt/extras/master/src/zram-setup.sh
	curl -O "$URL"; bash "${URL##*/}"
	unset -v URL

	# Symlink DASH to SH
	ln -sfT dash /bin/sh

	# Make it auto-symlink
	mkdir /etc/pacman.d/hooks
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/pacman.d/hooks/50-dash-symlink.hook
		[Trigger]
		Operation = Install
		Operation = Upgrade
		Type = Package
		Target = bash

		[Action]
		Depends = dash
		Description = Symlink dash to /bin/sh...
		When = PostTransaction
		Exec = /usr/bin/ln -sfT dash /bin/sh
	EOF

	# Enable services
	ufw enable
	systemctl disable dbus
	systemctl enable dbus-broker ufw apparmor auditd
	systemctl --global enable dbus-broker

	# Symlink 'bin' to 'sbin'
	rmdir /usr/local/sbin; ln -s bin /usr/local/sbin

	# Change 'doas.conf' and 'fstab' permissions
	groupadd -r doas; groupadd -r fstab
	echo 'permit :doas' > /etc/doas.conf
	chmod 640 /etc/{doas.conf,fstab}
	chown :doas /etc/doas.conf; chown :fstab /etc/fstab

	# Enable logging for apparmor, and enable caching
	groupadd -r audit
	sed -i '/log_group/s/root/audit/' /etc/audit/auditd.conf
	sed -i '/write-cache/s/#//' /etc/apparmor/parser.conf

	# Hardended system
	sed -i '/required/s/#//' /etc/pam.d/su
	sed -i '/required/s/#//' /etc/pam.d/su-l
	sed -i 's/ nullok//g' /etc/pam.d/system-auth
	echo '* hard core 0' >> /etc/security/limits.conf

	# Define groups
	Groups='proc,games,dbus,scanner,audit,fstab,doas,users'
	Groups+=',video,render,lp,kvm,input,audio,wheel'
	pacman -Q realtime-privileges &>/dev/null && Groups+=',realtime'

	# Create user
	while :; do
		read -p 'Your username: ' Username
		useradd -mG "$Groups" "$Username" && break
	done

	# Set a password
	while :; do passwd "$Username" && break; done
	unset -v Groups Username GPU

	# Download my keymaps
	URL=https://raw.githubusercontent.com/ides3rt/grammak/master/installer.sh
	curl -O "$URL"; bash "${URL##*/}"
	unset -v URL

	# My keymap
	File=/etc/vconsole.conf
	echo 'KEYMAP=grammak-iso' > "$File"
	pacman -Q terminus-font &>dev/null && echo 'FONT=ter-118b' >> "$File"
	unset -v File

	# Remove sudo(8)
	pacman -Rnsc --noconfirm sudo
	pacman -Sc --noconfirm

fi
