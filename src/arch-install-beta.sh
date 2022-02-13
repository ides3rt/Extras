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

# Encryption name
CryptNm=encrypt

sed -i '/RemoteFileSigLevel/s/#//' /etc/pacman.conf
sed -i "s/#ParallelDownloads = 5/ParallelDownloads = $(( $(nproc) + 1 ))/" /etc/pacman.conf

read Root _ <<< "$(ls -di /)"
read Init _ <<< "$(ls -di /proc/1/root/.)"

if (( Root == Init )); then

	# My keymap link
	URL=https://raw.githubusercontent.com/ides3rt/grammak/master/src/grammak-iso.map
	File="${URL##*/}"

	# Set my keymap
	curl -O "$URL"; gzip "$File"
	loadkeys "$File".gz 2>/dev/null
	rm -f "$File".gz; unset -v URL File

	read -p "This may not works as expected are you sure? (type 'yes' in all caps): "
	[[ $REPLY == YES ]] || exit 1

	# Partition, format, and mount the drive
	PS3='Select your disk: '
	select Disk in $(lsblk -dno PATH); do
		[[ -z $Disk ]] && continue

		parted "$Disk" mklabel gpt || exit 1
		sgdisk "$Disk" -n=1:0:+1024M -t=1:ef00
		sgdisk "$Disk" -n=2:0:0

		[[ $Disk == *nvme* ]] && P=p
		mkfs.fat -F 32 -n ESP "$Disk$P"1

		while :; do

			read -sp 'Your encryption password: ' Passwd
			printf '\n'

			read -sp 'Retype password again: ' RetypePasswd
			printf '\n'

			if [[ $Passwd == $RetypePasswd ]]; then
				echo "$Passwd" > /tmp/"$CryptNm".key
				unset -v Passwd RetypePasswd
				break
			fi

			print '%s\n' 'Err: Your passwd do not match...' 1>&2

		done

		cryptsetup --hash=sha512 --cipher=aes-xts-plain64 --key-file=/tmp/"$CryptNm".key --key-size=512 --allow-discards open --type=plain "$Disk$P"2 "$CryptNm"

		Mapper=/dev/mapper/"$CryptNm"
		mkfs.btrfs -f -L Arch "$Mapper"

		mount "$Mapper" /mnt
		btrfs su cr /mnt/@

		btrfs su cr /mnt/@/home
		btrfs su cr /mnt/@/opt
		btrfs su cr /mnt/@/root
		btrfs su cr /mnt/@/srv

		mkdir /mnt/@/usr
		btrfs su cr /mnt/@/usr/local

		mkdir -p /mnt/@/var/lib/libvirt
		btrfs su cr /mnt/@/var/cache
		btrfs su cr /mnt/@/var/lib/flatpak
		btrfs su cr /mnt/@/var/lib/libvirt/images
		btrfs su cr /mnt/@/var/local
		btrfs su cr /mnt/@/var/log
		btrfs su cr /mnt/@/var/opt
		btrfs su cr /mnt/@/var/spool
		btrfs su cr /mnt/@/var/tmp

		btrfs su cr /mnt/@/.snapshots
		mkdir /mnt/@/.snapshots/0
		btrfs su cr /mnt/@/.snapshots/0/snapshot
		btrfs su set-default /mnt/@/.snapshots/0/snapshot

		umount /mnt
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async "$Mapper" /mnt

		mkdir -p /mnt/{.snapshots,boot,home,opt,root,srv,usr/local,var/cache,var/local,var/log,var/opt,var/spool,var/tmp}
		chmod 700 /mnt/boot

		mkdir -p /mnt/var/lib/{flatpak,libvirt/images,machines,portables}
		chmod 700 /mnt/var/lib/{machines,portables}

		mount -o nosuid,nodev,noexec,noatime,fmask=0177,dmask=0077 "$Disk$P"1 /mnt/boot
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/home "$Mapper" /mnt/home
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/opt "$Mapper" /mnt/opt
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/root "$Mapper" /mnt/root
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/srv "$Mapper" /mnt/srv
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/usr/local "$Mapper" /mnt/usr/local
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/cache "$Mapper" /mnt/var/cache
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/lib/flatpak "$Mapper" /mnt/var/lib/flatpak
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/lib/libvirt/images "$Mapper" /mnt/var/lib/libvirt/images
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/local "$Mapper" /mnt/var/local
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/log "$Mapper" /mnt/var/log
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/opt "$Mapper" /mnt/var/opt
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/spool "$Mapper" /mnt/var/spool
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/var/tmp "$Mapper" /mnt/var/tmp
		mount -o noatime,compress-force=zstd:1,space_cache=v2,discard=async,subvol=@/.snapshots "$Mapper" /mnt/.snapshots

		unset -v Disk P Mapper
		break
	done

	# Install base packages
	pacstrap /mnt base base-devel linux-hardened linux-firmware neovim "$CPU"-ucode

	# Generate FSTAB
	genfstab -U /mnt > /mnt/etc/fstab
	sed -i 's/,subvol=\/@\/\.snapshots\/0\/snapshot//' /mnt/etc/fstab

	# Clean up FSTAB
	sed -i '/^#/d; s/,subvolid=[[:digit:]]*//; s/\/@/@/; s/rw,//; s/,ssd//; s/[[:space:]]/ /g' /mnt/etc/fstab

	# Optimize FSTAB
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF >> /mnt/etc/fstab
		tmpfs /tmp tmpfs nosuid,nodev,noatime,size=6G 0 0

		tmpfs /dev/shm tmpfs nosuid,nodev,noexec,noatime,size=1G 0 0

		proc /proc proc nosuid,nodev,noexec,gid=proc,hidepid=2 0 0

	EOF

	# Mount /tmp as tmpfs
	mount -t tmpfs -o nosuid,nodev,noatime,size=6G,mode=1777 tmpfs /tmp

	# Copy installer script to Chroot
	cp "$0" /tmp/"$CryptNm".key /mnt/tmp
	arch-chroot /mnt bash /tmp/"${0##*/}"

	# Remove /etc/resolv.conf as it's required for some
	# programs to work correctly with systemd-resolved
	rm -f /mnt/etc/resolv.conf

	# Unmount the partitions
	umount -R /mnt
	cryptsetup close "$CryptNm"

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

	# Set up localhost
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF >> /etc/hosts

		127.0.0.1 localhost
		::1 localhost
	EOF

	# Start networking services
	systemctl enable systemd-networkd systemd-resolved

	# Set up dhcp
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

	# Get /boot device source
	Disk=$(findmnt -o SOURCE --noheadings /boot)

	# Detect if it nvme or sata device
	if [[ $Disk == *nvme* ]]; then
		Modules='nvme nvme_core'
		Disk="${Disk/p*/}"
		P=p
	else
		Modules='ahci sd_mod'
		Disk="${Disk/[1-9]*/}"
	fi

	# Remove fallback preset
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

	# Set up initramfs cfg
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/mkinitcpio.conf
		MODULES=($Modules btrfs)
		BINARIES=()
		FILES=(/etc/cryptsetup-keys.d/$CryptNm.key)
		HOOKS=(systemd autodetect modconf keyboard sd-vconsole sd-encrypt)
		COMPRESSION="lz4"
		COMPRESSION_OPTIONS=(-12 --favor-decSpeed)
	EOF

	# Remove fallback img
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
	pacman -S --noconfirm "${AddsPkgs[@]}"
	unset AddsPkgs

	# Find rootfs UUID
	System=$(lsblk -o UUID --noheadings "$Disk$P"2 | tail -n 1)
	Mapper=$(findmnt -o UUID --noheadings /)

	# Specify the rootfs
	Kernel="root=UUID=$Mapper ro"

	# Specify the initrd files
	Kernel+=" initrd=\\$CPU-ucode.img initrd=\\initramfs-linux-hardened.img"

	# Speed improvement
	Kernel+=' quiet libahci.ignore_sss=1 zswap.enabled=0'

	# Enable apparmor
	Kernel+=' lsm=landlock,lockdown,yama,apparmor,bpf'

	# Install bootloader to UEFI
	efibootmgr --disk "$Disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\vmlinuz-linux-hardened' \
		--unicode "$Kernel"

	# Create directory for keyfile to live in
	mkdir /etc/cryptsetup-keys.d
	chmod 700 /etc/cryptsetup-keys.d

	# Create keyfile to auto-mount LUKS device
	mv /tmp/"$CryptNm".key /etc/cryptsetup-keys.d
	chmod 600 /etc/cryptsetup-keys.d/"$CryptNm".key

	# Add keyfile
	echo "$CryptNm UUID=$System none plain,cipher=aes-xts-plain64,discard,hash=sha512,size=512" > /etc/crypttab.initramfs
	unset -v CPU CryptNm Disk P Modules System Mapper Kernel

	# Select a GPU
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
		flatpak # Flatpak
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

	# Install kernel headers for DKMS modules
	[[ "$GPU" == nvidia-dkms ]] && OptsDeps+=( linux-hardened-headers )

	# Install "optional" packages
	pacman -S "$GPU" "${OptsPkgs[@]}"

	if (( $? == 0 )); then
		# Install optional deps
		pacman -S --asdeps --noconfirm "${OptsDeps[@]}"

		# Enable services
		systemctl --global enable pipewire-pulse
		sed -i '/encryption/s/luks1/luks2/' /etc/udisks2/udisks2.conf

		# Flatpak
		flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
		flatpak update

		# Create symlinks
		ln -s run/media /
		ln -sf /usr/share/fontconfig/conf.avail/10-hinting-slight.conf /etc/fonts/conf.d
		ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d
		ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d
	fi

	unset OptsPkgs OptsDeps

	# Install Zram script
	URL=https://raw.githubusercontent.com/ides3rt/extras/master/src/zram-setup.sh
	File=/tmp/"${URL##*/}"

	# Install Zram
	curl -o "$File" "$URL"; bash "$File"
	unset -v URL File

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

	# Enable logging for Apparmor, and enable caching
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

	# Create a user
	while :; do
		read -p 'Your username: ' Username
		useradd -mG "$Groups" "$Username" && break
	done

	# Set a password
	while :; do passwd "$Username" && break; done
	unset -v Groups Username GPU

	# My keymap script
	URL=https://raw.githubusercontent.com/ides3rt/grammak/master/installer.sh
	File=/tmp/"${URL##*/}"

	# Download my keymap
	curl -o "$File" "$URL"; bash "$File"
	rm -rf /grammak; unset -v URL File

	# My keymap
	File=/etc/vconsole.conf
	echo 'KEYMAP=grammak-iso' > "$File"
	pacman -Q terminus-font &>dev/null && echo 'FONT=ter-118b' >> "$File"
	unset -v File

	# Remove sudo(8)
	pacman -Rns --noconfirm sudo
	pacman -Sc --noconfirm

	# Create initramfs again -- for mature
	mkinitcpio -P

	# Use 700 for newly create files
	sed -i 's/022/077/' /etc/profile

fi
