#!/usr/bin/env bash

trap 'echo Interrupt signal received; exit' SIGINT

# Base repository's URL.
git_url=https://github.com/ides3rt
raw_url=https://raw.githubusercontent.com/ides3rt

# Use Grammak keymap or not.
grammak=true

# Use keyfile or not. Mind you that /boot is unencrypted.
# If keyfile is disable, then auto-login will be enable.
key_file=false

# Encryption name.
crypt_nm=luks0

# Detect CPU.
while read; do
	if [[ $REPLY == *vendor_id* ]]; then
		case $REPLY in
			*AMD*)
				cpu=amd ;;

			*Intel*)
				cpu=intel ;;
		esac
		break
	fi
done < /proc/cpuinfo

# Number of processors.
proc=$(( `nproc` + 1 ))

# Configure makepkg.conf(5).
url=$raw_url/setup/master/src/etc/makepkg.conf
curl -s "$url" | sed "/MAKEFLAGS=/s/[[:digit:]]/$proc/g" > /etc/makepkg.conf

# Configure pacman.conf(5).
url=$raw_url/setup/master/src/etc/pacman.conf
curl -s "$url" | sed "/ParallelDownloads/s/[[:digit:]]/$proc/g" > /etc/pacman.conf
unset -v proc

read root_id _ <<< "$(ls -di /)"
read init_id _ <<< "$(ls -di /proc/1/root/.)"

if (( root_id == init_id )); then

	if [[ $grammak == true ]]; then
		# My keymap link.
		url=$raw_url/grammak/master/src/grammak-iso.map
		file=${url##*/}

		# Download my keymap.
		curl -sO "$url"
		gzip "$file"

		# Set my keymap.
		loadkeys "$file".gz &>/dev/null

		# Remove the keymap file.
		rm -f "$file".gz
		unset -v url file
	fi

	# Partition, format, and mount the drive.
	PS3='Select your disk: '
	select disk in $(lsblk -dne 7 -o PATH); do
		[[ -z $disk ]] && continue

		parted "$disk" mklabel gpt || exit 1
		sgdisk "$disk" -n=1:0:+512M -t=1:ef00
		sgdisk "$disk" -n=2:0:0

		[[ $disk == *nvme* ]] && p=p
		mkfs.fat -F 32 -n ESP "$disk$p"1

		if [[ key_file == true ]]; then
			crypt_fm=(
				-h sha512 # Use SHA-512 instead
				-S 1 # Add to keyslot 1 instead of slot 0
				-i 5000 # Use itertime of 5 secs
			)
		fi

		while :; do
			cryptsetup -v "${crypt_fm[@]}" luksFormat "$disk$p"2 && break
		done
		unset key_file crypt_fm

		read rotation < /sys/block/"${disk#/dev/}"/queue/rotational

		if (( rotation == 0 )); then
			crypt_flags=(
				--perf-no_read_workqueue # Disable read queue
				--perf-no_write_workqueue # Disable write queue
				--persistent # Make it the default option
			)

			esp_flags=,discard # Enable 'discard'
		fi
		unset -v rotation

		cryptsetup -v "${crypt_flags[@]}" open "$disk$p"2 "$crypt_nm" || exit 1
		unset crypt_flags

		mapper=/dev/mapper/"$crypt_nm"
		mkfs.btrfs -f -L Arch "$mapper"

		mount "$mapper" /mnt
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
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2 "$mapper" /mnt

		mkdir -p /mnt/{.snapshots,boot,efi,home,opt,root,srv,'usr/local',var}
		chattr +C /mnt/{boot,efi,var}
		chmod 700 /mnt/{boot,efi,root}

		mount -o nosuid,nodev,noexec,noatime,fmask=0177,dmask=0077"$esp_flags" "$disk$p"1 /mnt/efi
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/boot "$mapper" /mnt/boot
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/home "$mapper" /mnt/home
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/opt "$mapper" /mnt/opt
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/root "$mapper" /mnt/root
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/srv "$mapper" /mnt/srv
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/usr/local "$mapper" /mnt/usr/local
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/var "$mapper" /mnt/var
		mount -o nodev,noatime,compress-force=zstd:1,space_cache=v2,subvol=@/.snapshots "$mapper" /mnt/.snapshots

		mkdir -p /mnt/state/var
		chattr +C /mnt/state/var

		mkdir -p /mnt/{,state/}var/lib/pacman
		mount --bind /mnt/state/var/lib/pacman /mnt/var/lib/pacman

		unset -v disk p mapper esp_flags
		break
	done

	# Create dummy directories, so systemd(1) doesn't make random subvol.
	mkdir -p /mnt/var/lib/{machines,portables}
	chmod 700 /mnt/var/lib/{machines,portables}

	# Install base packages.
	sed -i 's,usr/bin/sh,,' /etc/pacman.conf
	pacstrap /mnt base linux-hardened linux-hardened-headers linux-firmware neovim "$cpu"-ucode
	chattr +C /mnt/tmp

	# Generate fstab(5).
	args='/^#/d; s/[[:blank:]]+/ /g; s/rw,//; s/,ssd//; s/,subvolid=[[:digit:]]+//'
	args+='; s#/@#@#; s#,subvol=@/\.snapshots/0/snapshot##; /\/efi/s/.$/1/'
	args+='; s/,codepage=437,iocharset=ascii,shortname=mixed,utf8,errors=remount-ro//'
	args+='; /\/var\/lib\/pacman/d'
	genfstab -U /mnt | sed -E "$args" | cat -s > /mnt/etc/fstab
	unset -v cpu args

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

	# Copy install script to /mnt.
	if [[ -f $0 ]]; then
		cp "$0" /mnt/opt
		instll=${0##*/}
	else
		url=$raw_url/extras/master/src/arch-install.sh
		instll=${url##*/}

		curl -so /mnt/opt/"$instll" "$url"
		unset -v url
	fi

	# Run install script in chroot.
	arch-chroot /mnt bash /opt/"$instll"
	unset -v instll

	# Remove /etc/resolv.conf as it's required for some
	# programs to work correctly with systemd-resolved(8).
	rm -f /mnt/etc/resolv.conf

	# Unmount /mnt.
	umount -R /mnt
	cryptsetup close "$crypt_nm"

else

	# Set date and time.
	while :; do
		read -p 'Your timezone: ' Timezone
		[[ -f /usr/share/zoneinfo/$timezone ]] && break
		printf '%s\n' "Err: $timezone: not found..." 1>&2
	done

	ln -sf /usr/share/zoneinfo/"$timezone" /etc/localtime
	hwclock --systohc

	# Set locale.
	echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
	locale-gen
	echo 'LANG=en_US.UTF-8' > /etc/locale.conf

	# Hostname.
	read -p 'Your hostname: ' Hostname
	echo "$hostname" > /etc/hostname
	unset -v hostname

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
	disk=$(lsblk -nso PATH "$(findmnt -nvo SOURCE /)" | tail -n 1)

	# Detect if it NVMe or SATA device.
	if [[ $disk == *nvme* ]]; then
		modules='nvme nvme_core'
		disk=${disk%p*}; p=p
	else
		modules='ahci sd_mod'
		disk=${disk%%[1-9]}
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
		MODULES=($modules btrfs)
		BINARIES=()
		FILES=(/etc/cryptsetup-keys.d/$crypt_nm.key)
		HOOKS=(systemd autodetect modconf keyboard sd-vconsole sd-encrypt)
		COMPRESSION="lz4"
		COMPRESSION_OPTIONS=(-12 --favor-decSpeed)
	EOF

	if [[ $key_file == false ]]; then
		REPLY="${REPLY/\/etc\/cryptsetup-keys.d\/$crypt_nm.key}"
	fi

	printf '%s' "$REPLY" > /etc/mkinitcpio.conf

	# Create directories.
	mkdir -p /efi/EFI/ARCHX64

	# Remove fallback image.
	rm -f /boot/initramfs-linux-hardened-fallback.img

	add_pkg=(
		btrfs-progs # BTRFS support
		efibootmgr # UEFI manager
		dosfstools # FAT and it's derivative support
		moreutils # Unix tools
		autoconf automake bc bison fakeroot flex pkgconf # Development tools
		clang lld # Better C complier
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
		tlp # Power-saving tools
	)

	# Install additional packages.
	pacman -S --noconfirm "${add_pkg[@]}"
	pacman -S --noconfirm --asdeps llvm
	unset add_pkg

	# Find the rootfs UUID.
	root_id=$(lsblk -dno UUID "$disk$p"2)
	mapper_id=$(findmnt -no UUID /)

	# Options for LUKS.
	echo "$crypt_nm UUID=$root_id none password-echo=no" > /etc/crypttab.initramfs
	chmod 600 /etc/crypttab.initramfs

	# Specify the rootfs.
	kernel="root=UUID=$mapper_id ro"

	# Specify the initrd files.
	#
	# Must be commented out if mkinitcpio(8) is in used.
	#kernel+=" initrd=\\$cpu-ucode.img initrd=\\initramfs-linux-hardened.img"

	# Don't show kernel messages.
	kernel+=' quiet loglevel=0 rd.udev.log_level=0 rd.systemd.show_status=false'

	# Enable Apparmor.
	kernel+=' lsm=landlock,lockdown,yama,apparmor,bpf'

	# Enable all mitigations for Spectre 2.
	kernel+=' spectre_v2=on'

	# Disable Speculative Store Bypass.
	kernel+=' spec_store_bypass_disable=on'

	# Disable TSX, enable all mitigations for the TSX Async Abort
	# vulnerability and disable SMT.
	kernel+=' tsx=off tsx_async_abort=full,nosmt'

	# Enable all mitigations for the MDS vulnerability and disable SMT.
	kernel+=' mds=full,nosmt'

	# Enable all mitigations for the L1TF vulnerability and disable SMT
	# and L1D flush runtime control.
	kernel+=' l1tf=full,force'

	# Force disable SMT.
	kernel+=' nosmt=force'

	# Mark all huge pages in the EPT as non-executable to mitigate iTLB multihit.
	kernel+=' kvm.nx_huge_pages=force'

	# Distrust the CPU for initial entropy at boot as it is not possible to
	# audit, may contain weaknesses or a backdoor.
	kernel+=' random.trust_cpu=off'

	# Enable IOMMU to prevent DMA attacks.
	kernel+=' intel_iommu=on amd_iommu=on'

	# Disable the busmaster bit on all PCI bridges during very
	# early boot to avoid holes in IOMMU.
	#
	# Keep in mind that this cmd cause my system to fails.
	# However, it gets recommended by Whonix developers.
	#kernel+=' efi=disable_early_pci_dma'

	# Disable the merging of slabs of similar sizes.
	kernel+=' slab_nomerge'

	# Enable sanity checks (F) and redzoning (Z).
	kernel+=' slub_debug=FZ'

	# Zero memory at allocation and free time.
	kernel+=' init_on_alloc=1 init_on_free=1'

	# Makes the kernel panic on uncorrectable errors
	# in ECC memory that an attacker could exploit.
	kernel+=' mce=0'

	# Enable Kernel Page Table Isolation.
	#
	# This cmd is already get enforce by linux-hardended kernel.
	#kernel+=' pti=on'

	# Vsyscalls are obsolete, are at fixed addresses and are a target for ROP.
	kernel+=' vsyscall=none'

	# Enable page allocator freelist randomization.
	#
	# This cmd is already get enforce by linux-hardended kernel.
	#kernel+=' page_alloc.shuffle=1'

	# Gather more entropy during boot.
	kernel+=' extra_latent_entropy'

	# Restrict access to debugfs.
	kernel+=' debugfs=off'

	# Disable annoying OEM logo.
	kernel+=' bgrt_disable'

	# Disable SSS as it meant for server usage.
	kernel+=' libahci.ignore_sss=1'

	# Disable Watchdog as it meant for server usage.
	kernel+=' modprobe.blacklist=iTCO_wdt nowatchdog'

	# Remove console cursor blinking.
	#
	# Also, I don't recommended this if you're using disk encryption
	# on rootfs, unless you've a keyfile.
	[[ $key_file == true ]] && kernel+=' vt.global_cursor_default=0'

	# Disable zswap as we already enabled zram.
	kernel+=' zswap.enabled=0'

	echo "$kernel" > /etc/kernel/cmdline

	# Install bootloader to UEFI.
	efibootmgr --disk "$disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\EFI\ARCHX64\linux-hardended.efi'

	if [[ $key_file == true ]]; then
		# Create directory for keyfile to live in.
		mkdir /etc/cryptsetup-keys.d
		chmod 700 /etc/cryptsetup-keys.d

		# Create a keyfile to auto mount LUKS device.
		dd bs=8k count=1 if=/dev/urandom of=/etc/cryptsetup-keys.d/"$crypt_nm".key iflag=fullblock &>/dev/null
		chmod 600 /etc/cryptsetup-keys.d/"$crypt_nm".key

		# Add a keyfile.
		cryptsetup -v -h sha256 -S 0 -i 1000 luksAddKey "$disk$p"2 /etc/cryptsetup-keys.d/"$crypt_nm".key
	fi

	unset -v cpu crypt_nm disk p modules root_id mapper_id kernel

	# Detect a GPU driver.
	while read; do
		if [[ $REPLY == *VGA* ]]; then
			case $REPLY in
				*AMD*)
					gpu=xf86-video-amdgpu ;;

				*Intel*)
					gpu=xf86-video-intel ;;

				*NVIDIA*)
					gpu=nvidia-dkms ;;
			esac
			break
		fi
	done <<< "$(lspci)"

	base_url=$raw_url/setup/master/src

	(
		# Setup /etc/modprobe.d
		dir_url=$base_url/etc/modprobe.d
		cd "${dir_url#$base_url}"

		# 30-security.conf
		url=$dir_url/30-security.conf
		curl -sO "$url"

		# 50-nvidia.conf
		if [[ $gpu == *nvidia* ]]; then
			url=$dir_url/50-nvidia.conf
			curl -sO "$url"
		fi
	)

	(
		# Setup /etc/sysctl.d
		dir_url=$base_url/etc/sysctl.d
		cd "${dir_url#$base_url}"

		# 30-security.conf
		url=$dir_url/30-security.conf
		curl -sO "$url"

		# 50-printk.conf
		url=$dir_url/50-printk.conf
		curl -sO "$url"
	) && > /etc/ufw/sysctl.conf

	(
		# Setup /etc/udev/rules.d
		dir_url=$base_url/etc/udev/rules.d
		cd "${dir_url#$base_url}"

		# 60-ioschedulers.rules
		url=$dir_url/60-ioschedulers.rules
		curl -sO "$url"

		# 70-nvidia.rules
		if [[ $gpu == *nvidia* ]]; then
			url=$dir_url/70-nvidia.rules
			curl -sO "$url"
		fi
	)

	unset -v base_url

	opt_pkg=(
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
		exfatprogs # exFAT support
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

	opt_dep=(
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
	pacman -S "$gpu" "${opt_pkg[@]}"

	if (( $? == 0 )); then
		pacman -Q noto-fonts &>/dev/null && opt_dep+=( noto-fonts-emoji )

		# Install optional dependencies.
		yes | pacman -S --asdeps "${opt_dep[@]}"

		# Enable services.
		systemctl enable libvirtd.socket
		systemctl --global enable pipewire-pulse

		# Make X.Org run rootless by default.
		echo 'needs_root_rights = no' > /etc/X11/Xwrapper.config

		# Flatpak.
		flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
		flatpak update

		# Create symlinks.
		ln -s run/media /

		# Configure pipewire(1).
		if pacman -Q wireplumber &>/dev/null; then
			dir=/etc/wireplumber/main.lua.d
			mkdir -p "$dir"
			cp /usr/share/wireplumber/main.lua.d/50-alsa-config.lua "$dir"

			args='s/--\["session.suspend-timeout-seconds"\] = 5/\["session.suspend-timeout-seconds"\] = 0/'
			sed -i "$args" "$dir"/50-alsa-config.lua
			unset -v dir args
		fi

		# Better fonts.
		dir=/usr/share/fontconfig/conf.avail
		ln -sf "$dir"/{10-hinting-slight,10-sub-pixel-rgb,11-lcdfilter-default}.conf /etc/fonts/conf.d

		# Use LUKS2 in udisks(8).
		sed -i '/encryption/s/luks1/luks2/' /etc/udisks2/udisks2.conf
	fi

	unset gpu opt_pkg opt_dep dir

	# zram setup script.
	url=$raw_url/extras/master/src/zram-setup.sh
	file=/tmp/"${url##*/}"

	# Setup zram.
	curl -so "$file" "$url"
	bash "$file"

	# Fix sulogin(8).
	mkdir /etc/systemd/system/{emergency,rescue}.service.d
	read -d '' <<-EOF
		[Service]
		Environment=SYSTEMD_SULOGIN_FORCE=1
	EOF

	printf '%s' "$REPLY" > /etc/systemd/system/emergency.service.d/sulogin.conf
	printf '%s' "$REPLY" > /etc/systemd/system/rescue.service.d/sulogin.conf

	# Allow systemd-logind(8) to see /proc.
	mkdir /etc/systemd/system/systemd-logind.service.d
	read -d '' <<-EOF
		[Service]
		SupplementaryGroups=proc
	EOF

	printf '%s' "$REPLY" > /etc/systemd/system/systemd-logind.service.d/hidepid.conf

	# Limit /run/user/$UID size to 1 GiB.
	sed -i 's/#RuntimeDirectorySize=10%/RuntimeDirectorySize=1G/' /etc/systemd/logind.conf

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

	# Generate usbguard(1) rules.
	usbguard generate-policy > /etc/usbguard/rules.conf

	# Set default mode to AC.
	args='/TLP_DEFAULT_MODE=AC/s/#//'

	# Load 'powersave' CPU governor module.
	echo cpufreq_powersave > /etc/modules-load.d/cpufreq.conf

	# Make tlp(1) manage CPU governor.
	args+='; /CPU_SCALING_GOVERNOR/s/#//'

	# Change CPU governor.
	driver=$(< /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver)
	if [[ $driver == acpi-cpufreq ]]; then
		args+='; /CPU_SCALING_GOVERNOR_ON_AC/s/powersave/schedutil/'
	fi
	unset -v driver

	# CPU boost.
	args+='; /CPU_BOOST/s/#//'

	# Powersave stuff.
	args+='; /SCHED_POWERSAVE/s/#//'
	args+='; /SCHED_POWERSAVE_ON_AC/s/0/1/'

	# Get disk-id.
	while IFS=': ' read _ disk_id; do
		case $disk_id in
			usb-*|ieee1394-*)
				;;
			*)
				disk_arr+=("$disk_id") ;;
		esac
	done <<< "$(tlp diskid)"

	# Disk management.
	args+="; s/#DISK_DEVICES=.*/DISK_DEVICES=\"${disk_arr[*]}\"/"
	unset disk_id disk_arr

	# Runtime power management.
	args+='; /#AHCI_RUNTIME_PM_ON/s/#//'
	args+='; /AHCI_RUNTIME_PM_ON_AC/s/on/auto/'

	# Disable disk suspend.
	args+='; s/#AHCI_RUNTIME_PM_TIMEOUT=15/AHCI_RUNTIME_PM_TIMEOUT=0/'

	# Runtime power management for PCIe.
	args+='; /#RUNTIME_PM_ON/s/#//'
	args+='; /RUNTIME_PM_ON_AC/s/on/auto/'

	# Disable USB auto-suspend.
	args+='; s/#USB_AUTOSUSPEND=1/USB_AUTOSUSPEND=0/'

	# Configure tlp(1).
	sed -i "$args" /etc/tlp.conf
	unset -v disk args

	# Symlink bash(1) to rbash(1).
	ln -sT bash /usr/bin/rbash

	# Symlink dash(1) to sh(1).
	ln -sfT dash /usr/bin/sh

	# Enable services.
	ufw enable
	systemctl disable dbus
	systemctl enable apparmor auditd dbus-broker fcron tlp ufw usbguard
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
	while IFS=': ' read nr if_name _; do
		[[ $nr == 2 ]] && break
	done <<< "$(ip a)"

	# Enable MAC address randomizer service.
	systemctl enable macspoof@"$if_name"
	unset -v nr if_name

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
	url=https://raw.githubusercontent.com/Whonix/dist-base-files/master/etc/machine-id
	curl -s "$url" > /etc/machine-id
	unset -v url

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
	groups=audit,doas,users,lp,wheel

	# Groups that required if systemd-udevd(7) doesn't exist.
	if [[ ! -f /lib/systemd/systemd-udevd ]]; then
		groups+=,scanner,video,kvm,input,audio
	fi

	# Addition groups.
	pacman -Q libvirt &>/dev/null && Groups+=,libvirt
	pacman -Q realtime-privileges &>/dev/null && Groups+=,realtime

	# Create a user.
	while :; do
		read -p 'Your username: ' username
		useradd -mG "$groups" "$username" && break
	done

	if [[ $key_file == false ]]; then
		dir=/etc/systemd/system/getty@tty1.service.d
		file=$dir/autologin.conf

		# Auto login
		mkdir "$dir"
		read -d '' <<-EOF
			[Service]
			Type=simple
			ExecStart=
			ExecStart=-/sbin/agetty -a $username -i -J -n -N %I \$TERM
		EOF

		printf '%s' "$REPLY" > "$file"
		unset -v dir file
	fi

	# Set a password.
	while :; do passwd "$username" && break; done
	unset -v groups username

	# Specify vconsole.conf(5).
	vcon=/etc/vconsole.conf

	if [[ $grammak == true ]]; then
		# My keymap script.
		url=$git_url/grammak
		dir=/tmp/${url##*/}

		# Download my keymap.
		git clone -q "$url" "$dir"
		bash "$dir"/installer.sh

		# Make it the default.
		echo 'KEYMAP=grammak-iso' > "$vcon"
		unset -v url dir
	fi

	# If Terminus font is installed, then use it.
	if pacman -Q terminus-font &>dev/null; then
		echo 'FONT=ter-i18b' >> "$vcon"
	fi
	unset -v vcon

	# Create initramfs again -- for mature.
	mkinitcpio -P

	# Use 700 for newly create files and clean $PATH.
	sed -i 's/022/077/; /\/sbin/d' /etc/profile

	# Clean PATH.
	sed -i 's#/usr/local/sbin:##' /etc/login.defs

fi
