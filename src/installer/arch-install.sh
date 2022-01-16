#!/usr/bin/env bash

# Part 1

# Load my keymap
URL=https://raw.githubusercontent.com/ides3rt/colemak-dhk/master/src/colemak-dhk.map
curl -O "$URL"; gzip "${URL##*/}"
loadkeys "${URL##*/}".gz
unset -v URL

# Partition, format, and mount the drive
printf 'Partition, format, and mount your drive -- Also, you need to put ESP on /boot...\n'
bash

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

# Install base packages
pacstrap /mnt base base-devel linux linux-firmware vim "$CPU"-ucode

# Generate FSTAB
genfstab-U /mnt > /mnt/etc/fstab
echo 'proc /proc proc nosuid,nodev,noexec,gid=proc,hidepid=2 0 0' >> /mnt/etc/fstab

# Create install script
File=/mnt/arch-install2
echo '#!/usr/bin/env bash' > "$File"
echo "CPU=$CPU" >> "$File"
sed '0,/^# Part 2$/d' "$0" >> "$File"
chmod +x "$File"
unset -v File CPU

# Exit the script
arch-chroot /mnt ./arch-install2.sh
printf 'Done...\n'; exit 0

# Part 2

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
systemctl enable systemd-resolved systemd-networkd

while read; do
	printf '%s\n' "$REPLY"
done <<-EOF > /etc/systemd/network/20-dhcp.network
	[Match]
	Name=*
	[Network]
	DHCP=yes
	IPv6AcceptRA=true
	[DHCP]
	UseDNS=false
	[IPv6AcceptRA]
	UseDNS=false
	[Link]
	MACAddressPolicy=random
	NamePolicy=kernel database onboard slot path
EOF

while read; do
	printf '%s\n' "$REPLY"
done <<-EOF >> /etc/systemd/resolve.conf
	DNS=45.90.28.27
	DNS=2a07:a8c0::35:79e8
	FallbackDNS=45.90.30.27
	FallbackDNS=2a07:a8c1::35:79e8
EOF

# Install bootloader
echo "ParallelDownloads = $(( $(nproc) + 1 ))" >> /etc/pacman.conf
pacman -S --noconfirm efibootmgr dosfstools

# Get user data
System=$(findmnt -o UUID / | tail -n 1)
while :; do
	read -p 'Your disk [/dev/sda]: ' Disk
	[[ -b ${Disk:-/dev/sda} ]] && break
	printf 'Err: %s\n' "'$Disk' unknown blk device..." 1>&2
done

if [[ $Disk == *nvme* ]]; then
	Modules=nvme
else
	Modules='ahci sd_mod'
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
	MODULES=($Modules ext4)
	BINARIES=()
	FILES=()
	HOOKS=(base)
	COMPRESSION="xz"
	COMMPRESSION_OPTIONS=(-9 -e -T0)
EOF

rm -f /boot/initramfs-linux-fallback.img
mkinitcpio -P

# Boot parameter
KParmeter="root=UUID=$System ro initrd=\\$CPU-ucode.img"
KParmeter+=' initrd=\initramfs-linux.img quiet nosplash nowatchdog'

# Install bootloader to UEFI
efibootmgr --disk "${Disk:-/dev/sda}" --part 1 --create \\
	--label 'Arch Linux' \\
	--loader '\vmlinuz-linux' \\
	--unicode "$KParmeter"
unset -v System Disk Modules KParmeter CPU

# Install additional packages
pacman -S --noconfirm dash nvidia linux-headers xorg-server xorg-xinit \
	xorg-xsetroot xorg-xrandr git wget man-db htop ufw bspwm sxhkd \
	rxvt-unicode feh maim exfatprogs picom rofi xclip ffmpeg pipewire \
	pipewire-pulse mpv youtube-dl pigz pacman-contrib arc-solid-gtk-theme \
	papirus-icon-theme terminus-font zip unzip p7zip pbzip2 fzf pv rsync \
	bash-completion bc dunst libnotify rustup sccache xdotool \
	xcape pwgen dbus-broker tmux perl-image-exiftool archiso \
	firefox-developer-edition links opendoas
pacman -S --asdeps --noconfirm qemu edk2-ovmf memcached
rustup update stable; rustup self upgrade-data
ufw enable
systemctl disable dbus
systemctl enable dbus-broker fstrim.timer avahi-daemon ufw
systemctl --global enable dbus-broker
ln -s doas /usr/bin/sudo
ln -s vim /usr/bin/vi
ln -s vim /usr/bin/nano
ln -sf /usr/share/fontconfig/conf.avail/10-hinting-slight.conf /etc/fonts/conf.d/
ln -sf /usr/share/fontconfig/conf.avail/10-sub-pixel-rgb.conf /etc/fonts/conf.d/
ln -sf /usr/share/fontconfig/conf.avail/11-lcdfilter-default.conf /etc/fonts/conf.d/

# Networking
ufw enable

# Configuration
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
URL=https://raw.githubusercontent.com/ides3rt/colemak-dhk/master/installer.sh
curl -O "$URL"; bash "${URL##*/}"
unset -v URL

# My keymap
File=/etc/vconsole.conf
echo 'KEYMAP=colemak-dhk' > "$File"
echo 'FONT=ter-118b' >> "$File"
unset -v File

exit 0
