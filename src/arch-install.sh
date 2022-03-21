#!/usr/bin/env bash

trap 'echo Interrupt signal received; exit' SIGINT

# Base repository's URL.
git_url=https://github.com/ides3rt
raw_url=https://raw.githubusercontent.com/ides3rt

# Use keyfile or not. Mind you that /boot is unencrypted.
# If keyfile is disable, then auto-login will be enable.
use_keyfile=false

use_grammak=true
crypt_name=luks0

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
proc=$(( `nproc` + 1 ))

curl -s "$raw_url"/setup/master/src/etc/makepkg.conf | \
	sed -E "/MAKEFLAGS=/s/[[:digit:]]+/$proc/g" > /etc/makepkg.conf

curl -s "$raw_url"/setup/master/src/etc/pacman.conf | \
	sed -E "/ParallelDownloads/s/[[:digit:]]+/$proc/g" > /etc/pacman.conf

read root_id _ <<< "$(ls -di /)"
read init_id _ <<< "$(ls -di /proc/1/root/.)"

if (( root_id == init_id )); then
	unset -v root_id init_id

	if [[ $use_grammak == true ]]; then
		url=$raw_url/grammak/master/src/grammak-iso.map
		file=${url##*/}

		curl -sO "$url"
		gzip "$file"

		loadkeys "$file".gz &>/dev/null
		rm -f "$file".gz
		unset -v url file
	fi

	PS3='Select your disk: '
	select disk in $(lsblk -dne 7 -o PATH); do
		[[ -z $disk ]] && continue

		parted "$disk" mklabel gpt || exit 1
		sgdisk "$disk" -n=1:0:+512M -t=1:ef00
		sgdisk "$disk" -n=2:0:0

		[[ $disk == *nvme* ]] && p=p
		mkfs.fat -F 32 -n ESP "$disk$p"1

		if [[ $use_keyfile == true ]]; then
			format_opt=(-h sha512 -S 1 -i 5000)
		fi

		while :; do
			cryptsetup -v "${format_opt[@]}" luksFormat "$disk$p"2 && break
		done
		unset use_keyfile format_opt

		if (( $(< /sys/block/"${disk#/dev/}"/queue/rotational) == 0 )); then
			crypt_flags=(
				# Disable read and write queue
				# as it's only make sense for rotational disk.
				--perf-no_read_workqueue
				--perf-no_write_workqueue
				--persistent
			)

			esp_flags=,discard
		fi

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
		mount -o nodev,noatime,subvol=@/boot "$mapper" /mnt/boot
		mount -o nodev,noatime,subvol=@/home "$mapper" /mnt/home
		mount -o nodev,noatime,subvol=@/opt "$mapper" /mnt/opt
		mount -o nodev,noatime,subvol=@/root "$mapper" /mnt/root
		mount -o nodev,noatime,subvol=@/srv "$mapper" /mnt/srv
		mount -o nodev,noatime,subvol=@/usr/local "$mapper" /mnt/usr/local
		mount -o nodev,noatime,subvol=@/var "$mapper" /mnt/var
		mount -o nodev,noatime,subvol=@/.snapshots "$mapper" /mnt/.snapshots

		mkdir -p /mnt/state/var
		chattr +C /mnt/state/var

		mkdir -p /mnt/{,state/}var/lib/pacman
		mount --bind /mnt/state/var/lib/pacman /mnt/var/lib/pacman

		unset -v disk p mapper esp_flags
		break
	done

	# Create dummies , so systemd(1) doesn't make random subvol.
	mkdir -p /mnt/var/lib/{machines,portables}
	chmod 700 /mnt/var/lib/{machines,portables}

	# Allow /usr/bin/sh installation for once.
	sed -i 's,usr/bin/sh,,' /etc/pacman.conf

	pacstrap /mnt base linux-hardened linux-hardened-headers \
		linux-firmware neovim "$cpu"-ucode

	chattr +C /mnt/{dev,run,tmp,sys,proc}

	args='/^#/d; s/[[:blank:]]+/ /g; s/rw,//; s/,ssd//; s/,subvolid=[[:digit:]]+//'
	args+='; s#/@#@#; s#,subvol=@/\.snapshots/0/snapshot##'
	args+='; /\/efi/{s/.$/1/; s/,code.*-ro//}; /\/var\/lib\/pacman/d'
	genfstab -U /mnt | sed -E "$args" | cat -s > /mnt/etc/fstab
	unset -v cpu args

	# genfstab(8) doesn't handle bind-mount properly,
	# so we need to handle ourself.
	echo '/state/var/lib/pacman /var/lib/pacman none bind 0 0' >> /mnt/etc/fstab

	read -d '' <<-EOF

		tmpfs /tmp tmpfs nosuid,nodev,noatime,size=6G 0 0

		tmpfs /dev/shm tmpfs nosuid,nodev,noexec,noatime,size=1G 0 0

		tmpfs /run tmpfs nosuid,nodev,noexec,size=1G 0 0

		devtmpfs /dev devtmpfs nosuid,dev,noexec,size=0k 0 0

		proc /proc procfs nosuid,nodev,noexec,gid=proc,hidepid=2 0 0

	EOF

	printf '%s' "$REPLY" >> /mnt/etc/fstab

	mount -t tmpfs -o nosuid,nodev,noatime,size=6G,mode=1777 tmpfs /mnt/opt

	if [[ -f $0 ]]; then
		cp "$0" /mnt/opt
		instll=${0##*/}
	else
		url=$raw_url/extras/master/src/arch-install.sh
		instll=${url##*/}

		curl -so /mnt/opt/"$instll" "$url"
		unset -v url
	fi

	arch-chroot /mnt bash /opt/"$instll"
	unset -v instll

	# Remove /etc/resolv.conf as it's required for some
	# programs to work correctly with systemd-resolved(8).
	rm -f /mnt/etc/resolv.conf

	umount -R /mnt
	cryptsetup close "$crypt_nm"

else
	unset -v root_id init_id

	while :; do
		read -p 'Your timezone: ' Timezone
		[[ -f /usr/share/zoneinfo/$timezone ]] && break
		printf '%s\n' "Err: $timezone: not found..." 1>&2
	done

	ln -sf /usr/share/zoneinfo/"$timezone" /etc/localtime
	hwclock --systohc

	echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen
	locale-gen
	echo 'LANG=en_US.UTF-8' > /etc/locale.conf

	read -p 'Your hostname: ' hostname
	echo "$hostname" > /etc/hostname
	unset -v hostname

	read -d '' <<-EOF

		127.0.0.1 localhost
		::1 localhost
	EOF
	printf '%s' "$REPLY" >> /etc/hosts

	systemctl enable systemd-networkd systemd-resolved

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

	disk=$(lsblk -nso PATH "$(findmnt -nvo SOURCE /)" | tail -n 1)

	if [[ $disk == *nvme* ]]; then
		modules='nvme nvme_core'
		disk=${disk%p*}; p=p
	else
		modules='ahci sd_mod'
		disk=${disk%%[1-9]}
	fi

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

	read -d '' <<-EOF
		MODULES=($modules btrfs)
		BINARIES=()
		FILES=(/etc/cryptsetup-keys.d/$crypt_name.key)
		HOOKS=(systemd autodetect modconf keyboard sd-vconsole sd-encrypt)
		COMPRESSION="lz4"
		COMPRESSION_OPTIONS=(-12 --favor-decSpeed)
	EOF

	if [[ $use_keyfile == false ]]; then
		REPLY=${REPLY/FILES=(*.key)/FILES=()}
	fi

	printf '%s' "$REPLY" > /etc/mkinitcpio.conf

	mkdir -p /efi/EFI/ARCHX64
	rm -f /boot/initramfs-linux-hardened-fallback.img

	pacman -S --noconfirm btrfs-progs efibootmgr dosfstools moreutils autoconf \
		automake bc bison fakeroot flex pkgconf clang lld fcron opendoas ufw \
		apparmor usbguard man-db man-pages dash dbus-broker jitterentropy tlp \
		macchanger
	pacman -S --noconfirm --asdeps llvm

	root_id=$(lsblk -dno UUID "$disk$p"2)
	mapper_id=$(findmnt -no UUID /)

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
	efibootmgr --disk "$disk" --part 1 --create \
		--label 'Arch Linux' \
		--loader '\EFI\ARCHX64\linux-hardended.efi'

	if [[ $use_keyfile == true ]]; then
		mkdir /etc/cryptsetup-keys.d
		chmod 700 /etc/cryptsetup-keys.d

		dd bs=8k count=1 if=/dev/urandom iflag=fullblock \
			of=/etc/cryptsetup-keys.d/"$crypt_name".key
		chmod 600 /etc/cryptsetup-keys.d/"$crypt_name".key

		cryptsetup -v -h sha256 -S 0 -i 1000 luksAddKey \
			"$disk$p"2 /etc/cryptsetup-keys.d/"$crypt_name".key
	fi

	unset -v cpu crypt_name disk p modules root_id mapper_id kernel

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
		dir_url=$base_url/etc/modprobe.d
		cd "${dir_url#$base_url}"

		curl -sO "$dir_url"/30-security.conf

		if [[ $gpu == *nvidia* ]]; then
			curl -sO "$dir_url"/50-nvidia.conf
		fi
	)

	(
		dir_url=$base_url/etc/sysctl.d
		cd "${dir_url#$base_url}"

		curl -sO "$dir_url"/30-security.conf

		curl -sO "$dir_url"/50-printk.conf
	) && > /etc/ufw/sysctl.conf

	(
		dir_url=$base_url/etc/udev/rules.d
		cd "${dir_url#$base_url}"

		curl -sO "$dir_url"/60-ioschedulers.rules

		if [[ $gpu == *nvidia* ]]; then
			curl -sO "$dir_url"/70-nvidia.rules
		fi
	)

	unset -v base_url

	printf '%s\n' "Do you wanna dl opt-pkgs for author's dotfiles (iDes3rt)?"
	while :; do
		read -p '[y/N]: '
		case ${REPLY,,} in
			yes|y)
				# Pre-install dependencies, so it doesn't prompt
				# user what to be chosen.
				pacman -S --noconfirm --asdeps pipewire-jack \
					wireplumber noto-fonts

				pacman -S --noconfirm "$gpu" git wget rsync virt-manager htop \
					fzf tmux zip unzip pigz p7zip pbzip2 rustup sccache \
					arch-audit arch-wiki-lite archiso udisks2 exfatprogs \
					flatpak terminus-font pwgen xorg-server xorg-xrandr \
					xorg-xinit xdg-user-dirs arc-solid-gtk-theme \
					papirus-icon-theme redshift bspwm sxhkd xorg-xsetroot \
					rxvt-unicode rofi pipewire dunst picom feh sxiv maim \
					xdotool perl-image-exiftool firefox-developer-edition \
					links libreoffice pinta zathura mpv neofetch cowsay \
					cmatrix figlet sl fortune-mod lolcat doge

				# Don't use --noconfirm as there're confilt packages and
				# pacman(8) by default will answer 'no', instead of 'yes'.
				yes | pacman -S --asdeps qemu ebtables dnsmasq edk2-ovmf \
					lsof strace dialog bash-completion memcached libnotify \
					pipewire-pulse realtime-privileges rtkit yt-dlp aria2 \
					xclip zathura-pdf-mupdf noto-fonts-emoji

				systemctl enable libvirtd.socket
				systemctl --global enable pipewire-pulse

				ln -s run/media /
				echo 'needs_root_rights = no' > /etc/X11/Xwrapper.config

				flatpak remote-add --if-not-exists flathub \
					https://flathub.org/repo/flathub.flatpakrepo
				flatpak update

				dir=/etc/wireplumber/main.lua.d
				mkdir -p "$dir"
				cp /usr/share/wireplumber/main.lua.d/50-alsa-config.lua "$dir"
				sed -i '/suspend-timeout/{s/--//; s/5/0/}' "$dir"/*

				dir=/usr/share/fontconfig/conf.avail
				ln -s "$dir"/1{0-sub-pixel-rgb,1-lcdfilter-default}.conf \
					/etc/fonts/conf.d
				unset -v dir

				sed -i '/encryption/s/luks1/luks2/' /etc/udisks2/udisks2.conf
				break ;;

			no|n|'')
				break ;;

			*)
				printf '%s\n' "Err: $REPLY: invaild reply..." ;;
		esac
	done
	unset -v gpu

	url=$raw_url/extras/master/src/zram-setup.sh
	file=/tmp/${url##*/}

	curl -so "$file" "$url"
	bash "$file"

	systemd_dir=/etc/systemd/system

	# Force sulogin(8) to login as root.
	# This is required as we disable root account.
	mkdir "$systemd_dir"/{emergency,rescue}.service.d
	read -d '' <<-EOF
		[Service]
		Environment=SYSTEMD_SULOGIN_FORCE=1
	EOF
	printf '%s' "$REPLY" > "$systemd_dir"/emergency.service.d/sulogin.conf
	printf '%s' "$REPLY" > "$systemd_dir"/rescue.service.d/sulogin.conf

	# Allow systemd-logind(8) to see /proc.
	# This is only useful when 'gid=proc,hidepid=2' is used in fstab(5).
	mkdir "$systemd_dir"/systemd-logind.service.d
	read -d '' <<-EOF
		[Service]
		SupplementaryGroups=proc
	EOF
	printf '%s' "$REPLY" > "$systemd_dir"/systemd-logind.service.d/hidepid.conf
	unset -v systemd_dir

	sed -i '/RuntimeDirectorySize/{s/#//; s/10%/1G/}' /etc/systemd/logind.conf

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

	usbguard generate-policy > /etc/usbguard/rules.conf

	# Load 'powersave' CPU governor module as Arch Linux unload it by default.
	echo 'cpufreq_powersave' > /etc/modules-load.d/cpufreq.conf

	args='/TLP_DEFAULT_MODE=AC/s/#//'
	args+='; /SCALING_GOVERNOR/{s/#//; /AC/s/powersave/schedutil/}'
	args+='; /CPU_BOOST/s/#//'
	args+='; /SCHED_POWERSAVE/{s/#//; s/0/1/}'

	while IFS=': ' read _ disk_id; do
		case $disk_id in
			usb-*|ieee1394-*)
				;;
			*)
				disk_arr+=("$disk_id") ;;
		esac
	done <<< "$(tlp diskid)"

	args+="; /DISK_DEVICES/{s/#//; s/=.*/=\"${disk_arr[*]}\"/}"
	unset disk_id disk_arr

	args+='; /RUNTIME_PM_ON/{s/#//; s/on/auto/}'
	args+='; /AHCI_RUNTIME_PM_TIMEOUT/{s/#//; s/15/0/}'
	args+='; /USB_AUTOSUSPEND/{s/#//; s/1/0/}'

	sed -i "$args" /etc/tlp.conf
	unset -v args

	ln -sT bash /usr/bin/rbash
	ln -sfT dash /usr/bin/sh

	ufw enable
	systemctl disable dbus
	systemctl enable apparmor auditd dbus-broker fcron tlp ufw usbguard
	systemctl --global enable dbus-broker

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

	while IFS=': ' read nr if_name _; do
		[[ $nr == 2 ]] && break
	done <<< "$(ip a)"

	systemctl enable macspoof@"$if_name"
	unset -v nr if_name

	rmdir /usr/local/sbin
	ln -s bin /usr/local/sbin

	groupadd -r doas
	echo 'permit persist :doas' > /etc/doas.conf
	chmod 640 /etc/doas.conf
	chown :doas /etc/doas.conf

	groupadd -r audit
	sed -i '/log_group/s/root/audit/' /etc/audit/auditd.conf
	sed -i '/write-cache/s/#//' /etc/apparmor/parser.conf

	# Use the common Machine ID.
	url=https://raw.githubusercontent.com/Whonix/dist-base-files/master/etc/machine-id
	curl -s "$url" > /etc/machine-id
	unset -v url

	echo 'jitterentropy_rng' > /usr/lib/modules-load.d/jitterentropy.conf
	sed -i '/required/s/#//' /etc/pam.d/su{,-l}
	sed -i 's/ nullok//g' /etc/pam.d/system-auth
	sed -i '/^password/s/$/& rounds=65536/' /etc/pam.d/passwd
	echo '* hard core 0' >> /etc/security/limits.conf
	sed -i '/Storage/{s/#//; s/external/none/}' /etc/systemd/coredump.conf

	read -d '' <<-EOF
		# File which lists terminals from which root can log in.
		# See securetty(5) for details.
	EOF
	printf '%s' "$REPLY" > /etc/securetty

	passwd -l root

	groups=audit,doas,users,lp,wheel

	# Groups that required if systemd-udevd(7) doesn't exist.
	if [[ ! -f /lib/systemd/systemd-udevd ]]; then
		groups+=,scanner,video,kvm,input,audio
	fi

	pacman -Q libvirt &>/dev/null && Groups+=,libvirt
	pacman -Q realtime-privileges &>/dev/null && Groups+=,realtime

	while :; do
		read -p 'Your username: ' username
		useradd -mG "$groups" "$username" && break
	done

	if [[ $use_keyfile == false ]]; then
		dir=/etc/systemd/system/getty@tty1.service.d

		# Auto login
		mkdir "$dir"
		read -d '' <<-EOF
			[Service]
			Type=simple
			ExecStart=
			ExecStart=-/sbin/agetty -a $username -i -J -n -N %I \$TERM
		EOF

		printf '%s' "$REPLY" > "$dir"/autologin.conf
		unset -v dir
	fi

	while :; do
		passwd "$username" && break
	done
	unset -v groups username

	vcon=/etc/vconsole.conf

	if [[ $use_grammak == true ]]; then
		url=$git_url/grammak
		dir=/tmp/${url##*/}

		git clone -q "$url" "$dir"
		bash "$dir"/installer.sh

		echo 'KEYMAP=grammak-iso' > "$vcon"
		unset -v url dir
	fi

	if pacman -Q terminus-font &>dev/null; then
		echo 'FONT=ter-i18b' >> "$vcon"
	fi
	unset -v vcon

	mkinitcpio -P
	sed -i 's/022/077/; /\/sbin/d' /etc/profile
	sed -i 's#/usr/local/sbin:##' /etc/login.defs
fi
