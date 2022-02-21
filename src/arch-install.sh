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
CryptNm=luks0

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

	# Partition, format, and mount the drive
	PS3='Select your disk: '
	select Disk in $(lsblk -dno PATH); do
		[[ -z $Disk ]] && continue

		parted "$Disk" mklabel gpt || exit 1
		sgdisk "$Disk" -n=1:0:+1024M -t=1:ef00
		sgdisk "$Disk" -n=2:0:0

		[[ $Disk == *nvme* ]] && P=p
		mkfs.fat -F 32 -n ESP "$Disk$P"1

		cryptsetup -h sha512 luksFormat "$Disk$P"2
		cryptsetup open "$Disk$P"2 "$CryptNm" || exit 1

		Mapper=/dev/mapper/"$CryptNm"
		mkfs.btrfs -f -L Arch "$Mapper"

		mount "$Mapper" /mnt
		btrfs su cr /mnt/@

		btrfs su cr /mnt/@/home
		btrfs su cr /mnt/@/opt

		btrfs su cr /mnt/@/root
		chmod 700 /mnt/@/root

		btrfs su cr /mnt/@/srv

		mkdir /mnt/@/usr
		btrfs su cr /mnt/@/usr/local

		mkdir -p /mnt/@/var/lib/libvirt

		btrfs su cr /mnt/@/var/cache
		chattr +C /mnt/@/var/cache

		btrfs su cr /mnt/@/var/lib/flatpak

		btrfs su cr /mnt/@/var/lib/libvirt/images
		chattr +C /mnt/@/var/lib/libvirt/images

		btrfs su cr /mnt/@/var/local
		btrfs su cr /mnt/@/var/log
		btrfs su cr /mnt/@/var/opt
		btrfs su cr /mnt/@/var/spool

		btrfs su cr /mnt/@/var/tmp
		chattr +C /mnt/@/var/tmp
		chmod 1777 /mnt/@/var/tmp

		btrfs su cr /mnt/@/.snapshots
		mkdir /mnt/@/.snapshots/0
		btrfs su cr /mnt/@/.snapshots/0/snapshot
		btrfs su set-default /mnt/@/.snapshots/0/snapshot

		umount /mnt
		mount -o noatime,compress-force=zstd:1,space_cache=v2 "$Mapper" /mnt

		mkdir -p /mnt/{.snapshots,boot,home,opt,root,srv,usr/local,var/cache,var/local,var/log,var/opt,var/spool,var/tmp}

		chattr +C /mnt/var/cache
		chattr +C /mnt/var/tmp
		chmod 1777 /mnt/var/tmp
		chmod 700 /mnt/{boot,root}

		mkdir -p /mnt/var/lib/{flatpak,libvirt/images,machines,portables}
		chattr +C /mnt/var/lib/libvirt/images
		chmod 700 /mnt/var/lib/{machines,portables}

		mount -o nosuid,nodev,noexec,noatime,fmask=0177,dmask=0077 "$Disk$P"1 /mnt/boot
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/home "$Mapper" /mnt/home
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/opt "$Mapper" /mnt/opt
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/root "$Mapper" /mnt/root
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/srv "$Mapper" /mnt/srv
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/usr/local "$Mapper" /mnt/usr/local
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/cache "$Mapper" /mnt/var/cache
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/lib/flatpak "$Mapper" /mnt/var/lib/flatpak
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/lib/libvirt/images "$Mapper" /mnt/var/lib/libvirt/images
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/local "$Mapper" /mnt/var/local
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/log "$Mapper" /mnt/var/log
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/opt "$Mapper" /mnt/var/opt
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/spool "$Mapper" /mnt/var/spool
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var/tmp "$Mapper" /mnt/var/tmp
		mount -o noatime,compress-force=zstd:1,space_cache=v2,subvol=@/.snapshots "$Mapper" /mnt/.snapshots

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

	# Mount /mnt as tmpfs
	mount -t tmpfs -o nosuid,nodev,noatime,size=6G,mode=1777 tmpfs /mnt/mnt

	# Copy installer script to Chroot
	cp "$0" /mnt/mnt
	arch-chroot /mnt bash /mnt/"${0##*/}"

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
		DNSSEC=yes
		DNSOverTLS=yes
		IPv6PrivacyExtensions=true
		IPv6AcceptRA=true
		DNS=2a07:a8c0::#3579e8.dns1.nextdns.io
		DNS=45.90.28.0#3579e8.dns1.nextdns.io

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
		jitterentropy # Additional entropy source
		macchanger # MAC address spoof
		tlp cpupower # Power-saving tools
	)

	# Install additional packages
	pacman -S --noconfirm "${AddsPkgs[@]}"
	unset AddsPkgs

	# Find rootfs UUID
	System=$(lsblk -o UUID --noheadings --nodeps "$Disk$P"2)
	Mapper=$(findmnt -o UUID --noheadings /)

	# Options for LUKS
	Kernel="rd.luks.name=$System=$CryptNm"

	# Specify the rootfs
	Kernel+=" root=UUID=$Mapper ro"

	# Specify the initrd files
	Kernel+=" initrd=\\$CPU-ucode.img initrd=\\initramfs-linux-hardened.img"

	# Quiet
	Kernel+=' quiet loglevel=0'

	# Enable apparmor
	Kernel+=' lsm=landlock,lockdown,yama,apparmor,bpf'

	# Enable all mitigations for Spectre 2
	Kernel+=' spectre_v2=on'

	# Disable Speculative Store Bypass
	Kernel+=' spec_store_bypass_disable=on'

	# Disable TSX, enable all mitigations for the TSX Async Abort
	# vulnerability and disable SMT
	Kernel+=' tsx=off tsx_async_abort=full,nosmt'

	# Enable all mitigations for the MDS vulnerability and disable SMT
	Kernel+=' mds=full,nosmt'

	# Enable all mitigations for the L1TF vulnerability and disable SMT
	# and L1D flush runtime control
	Kernel+=' l1tf=full,force'

	# Force disable SMT
	Kernel+=' nosmt=force'

	# Mark all huge pages in the EPT as non-executable to mitigate iTLB multihit
	Kernel+=' kvm.nx_huge_pages=force'

	# Distrust the CPU for initial entropy at boot as it is not possible to
	# audit, may contain weaknesses or a backdoor
	Kernel+=' random.trust_cpu=off'

	# Enable IOMMU to prevent DMA attacks
	Kernel+=' intel_iommu=on amd_iommu=on'

	# Disable the busmaster bit on all PCI bridges during very
	# early boot to avoid holes in IOMMU.
	#
	# Keep in mind that this cmdline cause my system to fails
	# though it gets recommended by Whonix developers
	#Kernel+=' efi=disable_early_pci_dma'

	# Disable the merging of slabs of similar sizes
	Kernel+=' slab_nomerge'

	# Enable sanity checks (F) and redzoning (Z)
	Kernel+=' slub_debug=FZ'

	# Zero memory at allocation and free time
	Kernel+=' init_on_alloc=1 init_on_free=1'

	# Makes the kernel panic on uncorrectable errors in ECC memory that an attacker
	# could exploit
	Kernel+=' mce=0'

	# Enable Kernel Page Table Isolation
	#
	# This cmdline is already get enforce for linux-hardended kernel
	#Kernel+=' pti=on'

	# Vsyscalls are obsolete, are at fixed addresses and are a target for ROP
	Kernel+=' vsyscall=none'

	# Enable page allocator freelist randomization
	#
	# This cmdline is already get enforce for linux-hardended kernel
	#Kernel+=' page_alloc.shuffle=1'

	# Gather more entropy during boot
	Kernel+=' extra_latent_entropy'

	# Restrict access to debugfs
	Kernel+=' debugfs=off'

	# Speed improvement
	Kernel+=' libahci.ignore_sss=1 zswap.enabled=0'

	# Install bootloader to UEFI
	efibootmgr --disk "$Disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\vmlinuz-linux-hardened' \
		--unicode "$Kernel"

	# Create directory for keyfile to live in
	mkdir /etc/cryptsetup-keys.d
	chmod 700 /etc/cryptsetup-keys.d

	# Create keyfile to auto-mount LUKS device
	dd bs=512 count=4 if=/dev/urandom of=/etc/cryptsetup-keys.d/"$CryptNm".key iflag=fullblock &>/dev/null
	chmod 400 /etc/cryptsetup-keys.d/"$CryptNm".key
	chattr +i /etc/cryptsetup-keys.d/"$CryptNm".key

	# Add keyfile
	cryptsetup -v luksAddKey "$Disk$P"2 /etc/cryptsetup-keys.d/"$CryptNm".key
	unset -v CPU Disk P Modules System Mapper Kernel

	# Select a GPU
	PS3='Select your GPU [1-3]: '
	select GPU in xf86-video-amdgpu xf86-video-intel nvidia-dkms; do
		[[ -n $GPU ]] && break
	done

	OptsPkgs=(
		git wget rsync # Downloading tools
		virt-manager # Virtual machine
		htop # System monitor
		fzf # Command-line fuzzy finder
		tmux # Terminal multiplexer
		zip unzip # Additional compression algorithms
		pigz p7zip pbzip2 # Faster compression
		rustup sccache # Rust development
		bc # Linux kernel make deps
		arch-audit # Security checks in Arch Linux pkgs
		arch-wiki-lite # Arch Wiki
		archiso # Create Arch iso
		udisks2 # Mount drive via polkit(8)
		exfatprogs # ExFat support
		flatpak # Flatpak
		pacman-contrib # pacman(8) essentials
		terminus-font # Better TTY font
		pwgen # Password generator
		xorg-server xorg-xrandr # Xorg
		xorg-xinit # Display manager
		xdg-user-dirs # Manage XDG dirs
		arc-solid-gtk-theme papirus-icon-theme # GTK themes
		bspwm sxhkd xorg-xsetroot # bspwm(1) essentials
		rxvt-unicode # Terminal Emulater
		rofi # Programs launcher
		pipewire # Sound server
		dunst # Nofication daemon
		picom # Compositer
		feh # Wallpaper/Image viewer
		sxiv # Image viewer
		maim xdotool # Screenshot tools
		perl-image-exiftool # Image's metadata tools
		firefox-developer-edition links # Browsers
		libreoffice # Office programs
		gimp # Image editor
		zathura zathura-pdf-mupdf # PDF viewer
		mpv # Media player
		neofetch cowsay cmatrix figlet sl fortune-mod lolcat doge # Useless staff
	)

	OptsDeps=(
		qemu ebtables dnsmasq # Optional deps for libvirtd(8)
		edk2-ovmf # EFI support in Archiso
		lsof strace # Better htop(1)
		dialog # Interactive-menu in wiki-search(1)
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
	[[ $GPU == nvidia-dkms ]] && OptsDeps+=( linux-hardened-headers )

	# Install "optional" packages
	pacman -S "$GPU" "${OptsPkgs[@]}"

	if (( $? == 0 )); then
		pacman -Q noto-fonts &>/dev/null && OptsDeps+=( noto-fonts-cjk noto-fonts-emoji )

		# Install optional deps
		yes | pacman -S --asdeps "${OptsDeps[@]}"

		# Enable services
		systemctl enable libvirtd.socket
		systemctl --global enable pipewire-pulse

		# Enable nVidia service
		[[ $GPU == nvidia-dkms ]] && systemctl enable nvidia-persistenced

		# Flatpak
		flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
		flatpak update

		# Create symlinks
		ln -s run/media /
		ln -sf /usr/share/fontconfig/conf.avail/10-hinting-slight.conf /etc/fonts/conf.d
		ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d
		ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d

		# Use LUKS2 in udisks(8)
		sed -i '/encryption/s/luks1/luks2/' /etc/udisks2/udisks2.conf
	fi

	unset OptsPkgs OptsDeps

	# Install Zram script
	URL=https://raw.githubusercontent.com/ides3rt/extras/master/src/zram-setup.sh
	File=/tmp/"${URL##*/}"

	# Install Zram
	curl -o "$File" "$URL"
	bash "$File"
	unset -v URL File

	# Force BAT mode on TLP
	sed -i 's/#TLP_DEFAULT_MODE=AC/TLP_DEFAULT_MODE=BAT/' /etc/tlp.conf
	sed -i 's/#TLP_PERSISTENT_DEFAULT=0/TLP_PERSISTENT_DEFAULT=1/' /etc/tlp.conf

	# Enable powersave mode
	sed -i "s/#governor='ondemand'/governor='powersave'/" /etc/default/cpupower

	# Symlink BASH to RBASH
	ln -sfT bash /bin/rbash

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

	# Allow systemd-logind to see /proc
	mkdir /etc/systemd/system/systemd-logind.service.d
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/systemd/system/systemd-logind.service.d/hidepid.conf
		[Service]
		SupplementaryGroups=proc
	EOF

	# Enable services
	ufw enable
	systemctl disable dbus
	systemctl enable dbus-broker ufw apparmor auditd tlp cpupower
	systemctl --global enable dbus-broker

	# Create MAC address randomizer service
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/systemd/system/macspoof@.service
		[Unit]
		Description=macchanger on %I
		Wants=network-pre.target
		Before=network-pre.target
		BindsTo=sys-subsystem-net-devices-%i.device
		After=sys-subsystem-net-devices-%i.device

		[Service]
		ExecStart=/usr/bin/macchanger -e %I
		Type=oneshot

		[Install]
		WantedBy=multi-user.target
	EOF

	# Detect network interface
	while IFS=': ' read F1 Ifname _; do
		[[ $F1 == 2 ]] && break
	done <<< "$(ip a)"

	# Enable MAC address randomizer service
	systemctl enable macspoof@"$Ifname"
	unset -v F1 Ifname

	# Symlink 'bin' to 'sbin'
	rmdir /usr/local/sbin
	ln -s bin /usr/local/sbin

	# Change doas.conf(5) permissions
	groupadd -r doas
	echo 'permit persist :doas' > /etc/doas.conf
	chmod 640 /etc/doas.conf
	chown :doas /etc/doas.conf

	# Enable logging for Apparmor, and enable caching
	groupadd -r audit
	sed -i '/log_group/s/root/audit/' /etc/audit/auditd.conf
	sed -i '/write-cache/s/#//' /etc/apparmor/parser.conf

	# Required to be in wheel group for su(1)
	sed -i '/required/s/#//' /etc/pam.d/su
	sed -i '/required/s/#//' /etc/pam.d/su-l

	# Additional entropy source
	echo 'jitterentropy_rng' > /usr/lib/modules-load.d/jitterentropy.conf

	# Disallow null password
	sed -i 's/ nullok//g' /etc/pam.d/system-auth

	# Disable core dump
	echo '* hard core 0' >> /etc/security/limits.conf
	sed -i 's/#Storage=external/Storage=none/' /etc/systemd/coredump.conf

	# Disallow root to login to TTY
	while read; do
		printf '%s\n' "$REPLY"
	done <<-EOF > /etc/securetty
		# File which lists terminals from which root can log in.
		# See securetty(5) for details.
	EOF

	# Define groups
	Groups='audit,doas,users,lp,wheel'

	# Groups that required if systemD doesn't exists
	if [[ ! -f /lib/systemd/systemd ]]; then
		Groups+=',scanner,video,kvm,input,audio'
	fi

	# Addition groups
	pacman -Q libvirt &>/dev/null && Groups+=',libvirt'
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
