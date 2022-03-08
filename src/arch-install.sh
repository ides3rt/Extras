#!/usr/bin/env bash

trap 'echo Interrupt signal received; exit' SIGINT

# Use Grammak keymap or not. 1=yes, otherwise no.
Grammak="${Grammak:-1}"

# Use keyfile or not. 1=yes, otherwise no.
# Mind you that /boot partition is unencrypted.
# If keyfile is disable, then auto login will be enable.
KeyFile="${KeyFile:-0}"

# Detect CPU.
while read VendorID; do
	if [[ $VendorID == *vendor_id* ]]; then
		case "$VendorID" in
			*AMD*)
				CPU=amd ;;

			*Intel*)
				CPU=intel ;;
		esac
		break
	fi
done < /proc/cpuinfo
unset -v VendorID

# Encryption name.
CryptNm=luks0

# Configure pacman.conf(5).
URL=https://raw.githubusercontent.com/ides3rt/setup/master/src/etc/pacman.conf
curl -s "$URL" | sed "/ParallelDownloads/s/7/$(( $(nproc) + 1 ))/" > /etc/pacman.conf
unset -v URL

read Root _ <<< "$(ls -di /)"
read Init _ <<< "$(ls -di /proc/1/root/.)"

if (( Root == Init )); then

	if (( Grammak == 1 )); then
		# My keymap link.
		URL=https://raw.githubusercontent.com/ides3rt/grammak/master/src/grammak-iso.map
		File="${URL##*/}"

		# Download my keymap.
		curl -sO "$URL"
		gzip "$File"

		# Set my keymap.
		loadkeys "$File".gz 2>/dev/null

		# Remove that file.
		rm -f "$File".gz
		unset -v URL File
	fi

	# Partition, format, and mount the drive.
	PS3='Select your disk: '
	select Disk in $(lsblk -dne 7 -o PATH); do
		[[ -z $Disk ]] && continue

		parted "$Disk" mklabel gpt || exit 1
		sgdisk "$Disk" -n=1:0:+512M -t=1:ef00
		sgdisk "$Disk" -n=2:0:0

		[[ $Disk == *nvme* ]] && P=p
		mkfs.fat -F 32 -n ESP "$Disk$P"1

		if (( KeyFile == 1 )); then
			FormatFlags=(
				-h sha512 # Use SHA-512 instead
				-S 1 # Add to keyslot 1 instead of slot 0
				-i 5000 # Use itertime of 5 secs
			)
		fi

		while :; do
			cryptsetup -v "${FormatFlags[@]}" luksFormat "$Disk$P"2 && break
		done

		unset KeyFile FormatFlags

		read Rotation < /sys/block/"${Disk#/dev/}"/queue/rotational
		if (( Rotation == 0 )); then
			CryptFlags=(
				--perf-no_read_workqueue # Disable read queue
				--perf-no_write_workqueue # Disable write queue
				--persistent # Make it the default option
			)

			ESPFlags=,discard # Enable 'discard'
		fi

		unset -v Rotation

		cryptsetup -v "${CryptFlags[@]}" open "$Disk$P"2 "$CryptNm" || exit 1
		unset CryptFlags

		Mapper=/dev/mapper/"$CryptNm"
		mkfs.btrfs -f -L Arch "$Mapper"

		mount "$Mapper" /mnt
		btrfs su cr /mnt/@

		btrfs su cr /mnt/@/boot
		chattr +C /mnt/@/boot
		chmod 700 /mnt/@/boot

		btrfs su cr /mnt/@/home
		btrfs su cr /mnt/@/opt

		btrfs su cr /mnt/@/root
		chmod 700 /mnt/@/root

		btrfs su cr /mnt/@/srv

		mkdir /mnt/@/usr
		btrfs su cr /mnt/@/usr/local

		btrfs su cr /mnt/@/var
		chattr +C /mnt/@/var

		btrfs su cr /mnt/@/.snapshots
		mkdir /mnt/@/.snapshots/0
		btrfs su cr /mnt/@/.snapshots/0/snapshot
		btrfs su set-default /mnt/@/.snapshots/0/snapshot

		umount /mnt
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2 "$Mapper" /mnt

		mkdir -p /mnt/{.snapshots,boot,efi,home,opt,root,srv,'usr/local',var}
		chattr +C /mnt/{boot,efi,var}
		chmod 700 /mnt/{boot,efi,root}

		mount -o nosuid,nodev,noexec,noatime,fmask=0177,dmask=0077"$ESPFlags" "$Disk$P"1 /mnt/efi
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/boot "$Mapper" /mnt/boot
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/home "$Mapper" /mnt/home
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/opt "$Mapper" /mnt/opt
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/root "$Mapper" /mnt/root
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/srv "$Mapper" /mnt/srv
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/usr/local "$Mapper" /mnt/usr/local
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var "$Mapper" /mnt/var
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/.snapshots "$Mapper" /mnt/.snapshots

		mkdir -p /mnt/state/var
		chattr +C /mnt/state/var

		mkdir -p /mnt/{,state/}var/lib/pacman
		mount --bind /mnt/state/var/lib/pacman /mnt/var/lib/pacman

		unset -v Disk P Mapper ESPFlags
		break
	done

	# Create dummy directories, so systemd doesn't make random subvol.
	mkdir -p /mnt/var/lib/{machines,portables}
	chmod 700 /mnt/var/lib/{machines,portables}

	# Install base packages.
	sed -i 's,usr/bin/sh,,' /etc/pacman.conf
	pacstrap /mnt base linux-hardened linux-hardened-headers linux-firmware neovim "$CPU"-ucode
	chattr +C /mnt/tmp

	# Generate fstab(5).
	Args='/^#/d; s/[[:blank:]]+/ /g; s/rw,//; s/,ssd//; s/,subvolid=[[:digit:]]+//'
	Args+='; s#/@#@#; s#,subvol=@/\.snapshots/0/snapshot##; /\/efi/s/.$/1/'
	Args+='; s/,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro//'
	Args+='; /\/var\/lib\/pacman/d'
	genfstab -U /mnt | sed -E "$Args" | cat -s > /mnt/etc/fstab
	unset -v Args CPU

	# Make fstab(5) handle bind mount properly.
	echo '/state/var/lib/pacman /var/lib/pacman none bind 0 0' >> /mnt/etc/fstab

	# Optimize fstab(5).
	read -d '' <<-EOF

		tmpfs /tmp tmpfs nosuid,nodev,noatime,size=6G 0 0

		tmpfs /dev/shm tmpfs nosuid,nodev,noexec,noatime,size=1G 0 0

		tmpfs /run tmpfs nosuid,nodev,noexec,size=1G 0 0

		devtmpfs /dev devtmpfs nosuid,noexec,size=0k 0 0

		proc /proc procfs nosuid,nodev,noexec,gid=proc,hidepid=2 0 0

	EOF

	printf '%s' "$REPLY" >> /mnt/etc/fstab

	# Mount /mnt/opt as tmpfs.
	mount -t tmpfs -o nosuid,nodev,noatime,size=6G,mode=1777 tmpfs /mnt/opt

	# Copy installer script to /mnt.
	if [[ -f $0 ]]; then
		cp "$0" /mnt/opt
		Exec="${0##*/}"
	else
		URL=https://raw.githubusercontent.com/ides3rt/extras/master/src/arch-install.sh
		Exec="${URL##*/}"

		curl -so /mnt/opt/"$Exec" "$URL"
		unset -v URL
	fi

	# Run installer script in chroot.
	arch-chroot /mnt bash /opt/"$Exec"
	unset -v Exec

	# Remove /etc/resolv.conf as it's required for some
	# programs to work correctly with systemd-resolved.
	rm -f /mnt/etc/resolv.conf

	# Unmount /mnt.
	umount -R /mnt
	cryptsetup close "$CryptNm"

else

	# Set date and time.
	while :; do
		read -p 'Your timezone: ' Timezone
		[[ -f /usr/share/zoneinfo/$Timezone ]] && break
		printf '%s\n' "Err: '$Timezone' doesn't exists..." 1>&2
	done

	ln -sf /usr/share/zoneinfo/"$Timezone" /etc/localtime
	hwclock --systohc

	# Set locale.
	echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
	locale-gen
	echo 'LANG=en_US.UTF-8' > /etc/locale.conf

	# Hostname.
	read -p 'Your hostname: ' Hostname
	echo "$Hostname" > /etc/hostname
	unset -v Hostname

	# Set up localhost.
	read -d '' <<-EOF

		127.0.0.1 localhost
		::1 localhost
	EOF

	printf '%s' "$REPLY" >> /etc/hosts

	# Start networking services.
	systemctl enable systemd-networkd systemd-resolved

	# Set up dhcp.
	read -d '' <<-EOF
		[Match]
		Name=*

		[Network]
		DHCP=yes
		DNSSEC=yes
		DNSOverTLS=yes
		IPv6PrivacyExtensions=true
		IPv6AcceptRA=true
		DNS=45.90.28.0#3579e8.dns1.nextdns.io
		DNS=2a07:a8c0::#3579e8.dns1.nextdns.io

		[DHCP]
		UseDNS=false

		[IPv6AcceptRA]
		UseDNS=false
	EOF

	printf '%s' "$REPLY" > /etc/systemd/network/20-dhcp.network

	# Get device source.
	Disk=$(lsblk -nso PATH "$(findmnt -nvo SOURCE /)" | tail -n 1)

	# Detect if it NVMe or SATA device.
	if [[ $Disk == *nvme* ]]; then
		Modules='nvme nvme_core'
		Disk="${Disk/p*}"; P=p
	else
		Modules='ahci sd_mod'
		Disk="${Disk/[1-9]*}"
	fi

	# Remove fallback preset.
	read -d '' <<-EOF
		# mkinitcpio preset file for the 'linux-hardened' package.

		ALL_config="/etc/mkinitcpio.conf"
		ALL_kver="/boot/vmlinuz-linux-hardened"
		ALL_microcode=(/boot/*-ucode.img)

		PRESETS=('default')

		default_image="/boot/initramfs-linux-hardened.img"
		default_efi_image="/efi/EFI/ARCHX64/linux-hardended.efi"

		fallback_image="/boot/initramfs-linux-hardened-fallback.img"
		fallback_efi_image="/efi/EFI/ARCHX64/linux-hardended-fallback.efi"
		fallback_options="-S autodetect"
	EOF

	printf '%s' "$REPLY" > /etc/mkinitcpio.d/linux-hardened.preset

	# Set up initramfs configuration file.
	read -d '' <<-EOF
		MODULES=($Modules btrfs)
		BINARIES=()
		FILES=(/etc/cryptsetup-keys.d/$CryptNm.key)
		HOOKS=(systemd autodetect modconf keyboard sd-vconsole sd-encrypt)
		COMPRESSION="lz4"
		COMPRESSION_OPTIONS=(-12 --favor-decSpeed)
	EOF

	if (( KeyFile != 1 )); then
		REPLY="${REPLY/\/etc\/cryptsetup-keys.d\/$CryptNm.key}"
	fi

	printf '%s' "$REPLY" > /etc/mkinitcpio.conf

	# Create directories.
	mkdir -p /efi/EFI/ARCHX64

	# Remove fallback image.
	rm -f /boot/initramfs-linux-hardened-fallback.img

	AddsPkgs=(
		btrfs-progs # BTRFS support
		efibootmgr # UEFI manager
		dosfstools # Fat and it's derivative support
		moreutils # Unix tools
		autoconf automake bc bison fakeroot flex pkgconf # Development tools
		fcron # Cron tools
		opendoas # Privileges elevator
		ufw # Firewall
		apparmor # Applications sandbox
		usbguard # Protect from BadUSB
		man-db # An interface to system manuals
		man-pages # Linux manuals
		dash # Faster sh(1)
		dbus-broker # Better dbus(1)
		jitterentropy # Additional entropy source
		macchanger # MAC address spoof
		tlp cpupower # Power-saving tools
	)

	# Install additional packages.
	pacman -S --noconfirm "${AddsPkgs[@]}"
	unset AddsPkgs

	# Find the rootfs UUID.
	System=$(lsblk -dno UUID "$Disk$P"2)
	Mapper=$(findmnt -no UUID /)

	# Options for LUKS.
	echo "$CryptNm UUID=$System none password-echo=no" > /etc/crypttab.initramfs
	chmod 600 /etc/crypttab.initramfs

	# Specify the rootfs.
	Kernel="root=UUID=$Mapper ro"

	# Specify the initrd files.
	#
	# Must be commented out if mkinitcpio(8) is in used.
	#Kernel+=" initrd=\\$CPU-ucode.img initrd=\\initramfs-linux-hardened.img"

	# Don't show kernel messages.
	Kernel+=' quiet loglevel=0 rd.udev.log_level=0 rd.systemd.show_status=false'

	# Enable Apparmor.
	Kernel+=' lsm=landlock,lockdown,yama,apparmor,bpf'

	# Enable all mitigations for Spectre 2.
	Kernel+=' spectre_v2=on'

	# Disable Speculative Store Bypass.
	Kernel+=' spec_store_bypass_disable=on'

	# Disable TSX, enable all mitigations for the TSX Async Abort
	# vulnerability and disable SMT.
	Kernel+=' tsx=off tsx_async_abort=full,nosmt'

	# Enable all mitigations for the MDS vulnerability and disable SMT.
	Kernel+=' mds=full,nosmt'

	# Enable all mitigations for the L1TF vulnerability and disable SMT
	# and L1D flush runtime control.
	Kernel+=' l1tf=full,force'

	# Force disable SMT.
	Kernel+=' nosmt=force'

	# Mark all huge pages in the EPT as non-executable to mitigate iTLB multihit.
	Kernel+=' kvm.nx_huge_pages=force'

	# Distrust the CPU for initial entropy at boot as it is not possible to
	# audit, may contain weaknesses or a backdoor.
	Kernel+=' random.trust_cpu=off'

	# Enable IOMMU to prevent DMA attacks.
	Kernel+=' intel_iommu=on amd_iommu=on'

	# Disable the busmaster bit on all PCI bridges during very
	# early boot to avoid holes in IOMMU.
	#
	# Keep in mind that this cmd cause my system to fails.
	# However, it gets recommended by Whonix developers.
	#Kernel+=' efi=disable_early_pci_dma'

	# Disable the merging of slabs of similar sizes.
	Kernel+=' slab_nomerge'

	# Enable sanity checks (F) and redzoning (Z).
	Kernel+=' slub_debug=FZ'

	# Zero memory at allocation and free time.
	Kernel+=' init_on_alloc=1 init_on_free=1'

	# Makes the kernel panic on uncorrectable errors
	# in ECC memory that an attacker could exploit.
	Kernel+=' mce=0'

	# Enable Kernel Page Table Isolation.
	#
	# This cmd is already get enforce by linux-hardended kernel.
	#Kernel+=' pti=on'

	# Vsyscalls are obsolete, are at fixed addresses and are a target for ROP.
	Kernel+=' vsyscall=none'

	# Enable page allocator freelist randomization.
	#
	# This cmd is already get enforce by linux-hardended kernel.
	#Kernel+=' page_alloc.shuffle=1'

	# Gather more entropy during boot.
	Kernel+=' extra_latent_entropy'

	# Restrict access to debugfs.
	Kernel+=' debugfs=off'

	# Disable Intel P-State.
	Kernel+=' intel_pstate=disable'

	# Disable annoying OEM logo.
	Kernel+=' bgrt_disable'

	# Disable SSS as it meant for server usage.
	Kernel+=' libahci.ignore_sss=1'

	# Disable Watchdog as it meant for server usage.
	Kernel+=' modprobe.blacklist=iTCO_wdt nowatchdog'

	# Remove console cursor blinking.
	#
	# Also, I don't recommended this if you're using disk encryption
	# on rootfs, unless you've a keyfile.
	(( KeyFile == 1 )) && Kernel+=' vt.global_cursor_default=0'

	# Disable ZSwap as we already enabled ZRam.
	Kernel+=' zswap.enabled=0'

	echo "$Kernel" > /etc/kernel/cmdline

	# Install bootloader to UEFI.
	efibootmgr --disk "$Disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\EFI\ARCHX64\linux-hardended.efi'

	if (( KeyFile == 1 )); then

		# Create directory for keyfile to live in.
		mkdir /etc/cryptsetup-keys.d
		chmod 700 /etc/cryptsetup-keys.d

		# Create a keyfile to auto mount LUKS device.
		dd bs=8k count=1 if=/dev/urandom of=/etc/cryptsetup-keys.d/"$CryptNm".key iflag=fullblock &>/dev/null
		chmod 600 /etc/cryptsetup-keys.d/"$CryptNm".key

		# Add a keyfile.
		cryptsetup -v -h sha256 -S 0 -i 1000 luksAddKey "$Disk$P"2 /etc/cryptsetup-keys.d/"$CryptNm".key

	fi

	unset -v CryptNm CPU Disk P Modules System Mapper Kernel

	# Detect a GPU driver.
	while read Brand; do
		if [[ $Brand == *VGA* ]]; then
			case "$Brand" in
				*AMD*)
					GPU=xf86-video-amdgpu ;;

				*Intel*)
					GPU=xf86-video-intel ;;

				*NVIDIA*)
					GPU=nvidia-dkms ;;
			esac
			break
		fi
	done <<< "$(lspci)"
	unset -v Brand

	# Setup /etc/modprobe.d, /etc/sysctl.d, and /etc/udev/rules.d.
	(
		cd /etc/modprobe.d
		BaseURL=https://raw.githubusercontent.com/ides3rt/setup/master/src/etc/modprobe.d
		curl -sO "$BaseURL"/30-security.conf
		[[ $GPU == *nvidia* ]] && curl -sO "$BaseURL"/50-nvidia.conf

		cd /etc/sysctl.d
		BaseURL=https://github.com/ides3rt/setup/raw/master/src/etc/sysctl.d
		curl -sO "$BaseURL"/99-sysctl.conf

		cd /etc/udev/rules.d
		BaseURL=https://raw.githubusercontent.com/ides3rt/setup/master/src/etc/udev/rules.d
		curl -sO "$BaseURL"/60-ioschedulers.rules
		[[ $GPU == *nvidia* ]] && curl -sO "$BaseURL"/70-nvidia.rules
	)

	OptsPkgs=(
		git wget rsync # Downloading tools
		virt-manager # Virtual machine
		htop # System monitor
		fzf # Command-line fuzzy finder
		tmux # Terminal multiplexer
		zip unzip # Additional compression algorithms
		pigz p7zip pbzip2 # Faster compression
		rustup sccache # Rust development
		arch-audit # Security checks in Arch Linux pkgs
		arch-wiki-lite # Arch Wiki
		archiso # Create Arch iso
		udisks2 # Mount drive via polkit(8)
		exfatprogs # ExFat support
		flatpak # Flatpak
		terminus-font # Better TTY font
		pwgen # Password generator
		xorg-server xorg-xrandr # Xorg
		xorg-xinit # Display manager
		xdg-user-dirs # Manage XDG dirs
		arc-solid-gtk-theme papirus-icon-theme # GTK themes
		redshift # Eyes saver
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
		pinta # Image editor
		zathura # Document viewer
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
		zathura-pdf-mupdf # PDF support zathura(1)
	)

	# Install "optional" packages.
	pacman -S "$GPU" "${OptsPkgs[@]}"

	if (( $? == 0 )); then
		pacman -Q noto-fonts &>/dev/null && OptsDeps+=( noto-fonts-emoji )

		# Install optional dependencies.
		yes | pacman -S --asdeps "${OptsDeps[@]}"

		# Enable services.
		systemctl enable libvirtd.socket
		systemctl --global enable pipewire-pulse

		# Make X.org run rootless by default.
		echo 'needs_root_rights = no' > /etc/X11/Xwrapper.config

		# Flatpak.
		flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
		flatpak update

		# Create symlinks.
		ln -s run/media /

		Dir=/usr/share/fontconfig/conf.avail
		ln -sf "$Dir"/{10-hinting-slight,10-sub-pixel-rgb,11-lcdfilter-default}.conf /etc/fonts/conf.d

		# Use LUKS2 in udisks(8).
		sed -i '/encryption/s/luks1/luks2/' /etc/udisks2/udisks2.conf
	fi

	unset GPU OptsPkgs OptsDeps Dir

	# Download ZRam script.
	URL=https://raw.githubusercontent.com/ides3rt/extras/master/src/zram-setup.sh
	File=/tmp/"${URL##*/}"

	# Install ZRam.
	curl -so "$File" "$URL"
	bash "$File"
	unset -v URL File

	# Generate usbguard(1) rules.
	usbguard generate-policy > /etc/usbguard/rules.conf

	# Configure tlp(1).
	Args='s/#TLP_DEFAULT_MODE=AC/TLP_DEFAULT_MODE=BAT/'
	Args+='; s/#TLP_PERSISTENT_DEFAULT=0/TLP_PERSISTENT_DEFAULT=1/'
	Args+='; s/#USB_AUTOSUSPEND=1/USB_AUTOSUSPEND=0/'
	sed -i "$Args" /etc/tlp.conf
	unset -v Args

	# Enable 'schedutil' governor.
	sed -i "s/#governor='ondemand'/governor='schedutil'/" /etc/default/cpupower

	# Symlink bash(1) to rbash(1).
	ln -sT bash /usr/bin/rbash

	# Symlink dash(1) to sh(1).
	ln -sfT dash /usr/bin/sh

	# Setup tmpfiles.
	read -d '' <<-EOF
		# See tmpfiles.d(5) for details.

		# Remove file(s) in /tmp on reboot.
		q /tmp 1777 root root 0

		# Exclude namespace mountpoint(s) from removal.
		x /tmp/systemd-private-*
		X /tmp/systemd-private-*/tmp

		# Remove file(s) in /var/tmp older than 1 week.
		q /var/tmp 1777 root root 1w

		# Exclude namespace mountpoint(s) from removal.
		x /var/tmp/systemd-private-*
		X /var/tmp/systemd-private-*/tmp
	EOF

	printf '%s' "$REPLY" > /etc/tmpfiles.d/tmp.conf

	# Allow systemd-logind to see /proc.
	mkdir /etc/systemd/system/systemd-logind.service.d
	read -d '' <<-EOF
		[Service]
		SupplementaryGroups=proc
	EOF

	printf '%s' "$REPLY" > /etc/systemd/system/systemd-logind.service.d/hidepid.conf

	# Limit /proc/user/$UID size to 1 GiB.
	sed -i 's/#RuntimeDirectorySize=10%/RuntimeDirectorySize=1G/' /etc/systemd/logind.conf

	# Enable services.
	ufw enable
	systemctl disable dbus
	systemctl enable apparmor auditd cpupower dbus-broker fcron tlp ufw usbguard
	systemctl --global enable dbus-broker

	# Create MAC address randomizer service.
	read -d '' <<-EOF
		[Unit]
		Description=Macchanger on %I
		Wants=network-pre.target
		Before=network-pre.target
		BindsTo=sys-subsystem-net-devices-%i.device
		After=sys-subsystem-net-devices-%i.device

		[Service]
		Type=oneshot
		RemainAfterExit=yes
		ExecStart=/usr/bin/macchanger -e %I
		ExecReload=/usr/bin/macchanger -e %I
		ExecStop=/usr/bin/macchanger -p %I

		[Install]
		WantedBy=multi-user.target
	EOF

	printf '%s' "$REPLY" > /etc/systemd/system/macspoof@.service

	# Detect network interface.
	while IFS=': ' read F1 Ifname _; do
		[[ $F1 == 2 ]] && break
	done <<< "$(ip a)"

	# Enable MAC address randomizer service.
	systemctl enable macspoof@"$Ifname"
	unset -v F1 Ifname

	# Symlink /usr/local/bin to /usr/local/sbin.
	rmdir /usr/local/sbin
	ln -s bin /usr/local/sbin

	# Change doas.conf(5) permissions.
	groupadd -r doas
	echo 'permit persist :doas' > /etc/doas.conf
	chmod 640 /etc/doas.conf
	chown :doas /etc/doas.conf

	# Enable logging and enable caching for Apparmor.
	groupadd -r audit
	sed -i '/log_group/s/root/audit/' /etc/audit/auditd.conf
	sed -i '/write-cache/s/#//' /etc/apparmor/parser.conf

	# Use the common Machine ID.
	URL=https://raw.githubusercontent.com/Whonix/dist-base-files/master/etc/machine-id
	curl -s "$URL" > /etc/machine-id
	unset -v URL

	# Additional entropy source.
	echo 'jitterentropy_rng' > /usr/lib/modules-load.d/jitterentropy.conf

	# Required to be in wheel group for su(1).
	sed -i '/required/s/#//' /etc/pam.d/su{,-l}

	# Disallow null password.
	sed -i 's/ nullok//g' /etc/pam.d/system-auth

	# Make store password more secure.
	sed -i '/^password/s/$/& rounds=65536/' /etc/pam.d/passwd

	# Disable core dump.
	echo '* hard core 0' >> /etc/security/limits.conf
	sed -i 's/#Storage=external/Storage=none/' /etc/systemd/coredump.conf

	# Disallow root to login to TTY.
	read -d '' <<-EOF
		# File which lists terminals from which root can log in.
		# See securetty(5) for details.
	EOF

	printf '%s' "$REPLY" > /etc/securetty

	# Lock root account.
	passwd -l root

	# Define groups.
	Groups=audit,doas,users,lp,wheel

	# Groups that required if systemd doesn't exists.
	if [[ ! -f /lib/systemd/systemd ]]; then
		Groups+=,scanner,video,kvm,input,audio
	fi

	# Addition groups.
	pacman -Q libvirt &>/dev/null && Groups+=,libvirt
	pacman -Q realtime-privileges &>/dev/null && Groups+=,realtime

	# Create a user.
	while :; do
		read -p 'Your username: ' Username
		useradd -mG "$Groups" "$Username" && break
	done

	if (( KeyFile != 1 )); then

		Dir=/etc/systemd/system/getty@tty1.service.d
		File="$Dir"/autologin.conf

		# Auto login
		mkdir "$Dir"
		read -rd '' <<-EOF
			[Service]
			Type=simple
			ExecStart=
			ExecStart=-/sbin/agetty -8 -a $Username -i -n -N -o '-p -f -- \\\\u' - \$TERM
		EOF

		printf '%s' "$REPLY" > "$File"
		unset -v Dir File

	fi

	# Set a password.
	while :; do passwd "$Username" && break; done
	unset -v Groups Username

	# Specify vconsole.conf(5).
	VConsole=/etc/vconsole.conf

	if (( Grammak == 1 )); then
		# My keymap script.
		URL=https://raw.githubusercontent.com/ides3rt/grammak/master/installer.sh
		File=/tmp/"${URL##*/}"

		# Download my keymap.
		curl -so "$File" "$URL"
		(cd /tmp; bash "$File")
		unset -v URL File

		echo 'KEYMAP=grammak-iso' > "$VConsole"
	fi

	# If Terminus font is installed, then use it.
	if pacman -Q terminus-font &>dev/null; then
		echo 'FONT=ter-i18b' >> "$VConsole"
	fi

	unset -v VConsole

	# Remove sudo(8).
	pacman -Rns --noconfirm sudo
	pacman -Sc --noconfirm

	# Create initramfs again -- for mature.
	mkinitcpio -P

	# Use 700 for newly create files and clean PATH.
	sed -i 's/022/077/; /\/sbin/d' /etc/profile

	# Clean PATH.
	sed -i 's#/usr/local/sbin:##' /etc/login.defs

fi
