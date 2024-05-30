# The disk that will be used
# NOTE: If installing on an nvme drive (ie: /dev/nvme0n1), you'll need to replace all occurrences of ${DISK}# with ${DISK}p# where # is the partition number.
# Don't forget to also replace all occurences of $(echo $DISK | cut -f1 -d\ )# with $(echo $DISK | cut -f1 -d\ )p#
export DISK='/dev/vda'

export LUKS_KEY_DISK=cryptkey
export KEYFILE_LOCATION=/cryptkey
export KEY_DISK=/dev/mapper/cryptkey

# we use parted here since it does a good job with adding BIOS protective MBR to GPT disk
# since we are booting in BIOS mode, we get a max of 4 primary partitions
# BIOS MBR partition (1MB)
# /boot partition (1GB)
# LUKS key partition (20MB)
# LUKS swap partition (2GB)
# ZFS root partition (Remaining space)
# NOTE: Make the ZFS root partition your last partition, so that if you resize the disk it will be easy to get ZFS to use the extra space
parted --script $DISK mklabel gpt
parted --script --align optimal $DISK -- mklabel gpt mkpart 'BIOS-boot' 1MB 2MB set 1 bios_grub on mkpart 'boot' 2MB 1026MB mkpart 'luks-key' 1026MB 1046MB mkpart 'luks-swap' 1046MB 3094MB mkpart 'zfs-pool' 3094MB '100%'

# tr -d '\n' < /dev/urandom | dd of=/dev/disk/by-partlabel/key
# Create an encrypted disk to hold our key, the key to this drive
# is what you'll type in to unlock the rest of your drives... so,
# remember it:
export DISK1_KEY=$(echo $DISK | cut -f1 -d\ )3
cryptsetup luksFormat $DISK1_KEY
cryptsetup luksOpen $DISK1_KEY cryptkey

# Write the key right to the decrypted LUKS partition, as raw bytes
echo "" > newline
dd if=/dev/zero bs=1 count=1 seek=1 of=newline
dd if=/dev/urandom bs=32 count=1 | od -A none -t x | tr -d '[:space:]' | cat - newline > hdd.key
dd if=/dev/zero of=$KEY_DISK
dd if=hdd.key of=$KEY_DISK
dd if=$KEY_DISK bs=64 count=1

# Format swap as encrypted LUKS and mount the partition
export DISK1_SWAP=$(echo $DISK | cut -f1 -d\ )4
cryptsetup luksFormat --key-file=$KEY_DISK --keyfile-size=64 $DISK1_SWAP
cryptsetup open --key-file=$KEY_DISK --keyfile-size=64 $DISK1_SWAP cryptswap
mkswap /dev/mapper/cryptswap
swapon /dev/mapper/cryptswap

# Create root pool
zpool create -f \
	-o ashift=12 \
	-o autotrim=on \
	-R /mnt \
	-O acltype=posixacl \
	-O compression=zstd \
	-O dnodesize=auto \
	-O normalization=formD \
	-O xattr=sa \
	-O atime=off \
	-O canmount=off \
	-O mountpoint=none \
	-O encryption=aes-256-gcm \
	-O keylocation=file://$KEY_DISK \
	-O keyformat=hex \
	rpool \
	${DISK}5

# Create root system containers
zfs create \
	-o canmount=off \
	-o mountpoint=none \
	rpool/local
zfs create \
	-o canmount=off \
	-o mountpoint=none \
	rpool/safe

# Create and mount dataset for `/`
zfs create -p -o mountpoint=legacy rpool/local/root
# Create a blank snapshot
zfs snapshot rpool/local/root@blank
# Mount root ZFS dataset
mount -t zfs rpool/local/root /mnt

# Create and mount dataset for `/nix`
zfs create -p -o mountpoint=legacy rpool/local/nix
mkdir -p /mnt/nix
mount -t zfs rpool/local/nix /mnt/nix

# Create and mount dataset for `/home`
zfs create -p -o mountpoint=legacy rpool/safe/home
mkdir -p /mnt/home
mount -t zfs rpool/safe/home /mnt/home

# Create and mount dataset for `/persist`
zfs create -p -o mountpoint=legacy rpool/safe/persist
mkdir -p /mnt/persist
mount -t zfs rpool/safe/persist /mnt/persist

# Create and mount dataset for `/services`
zfs create -p -o mountpoint=legacy rpool/safe/services
mkdir -p /mnt/services
mount -t zfs rpool/safe/services /mnt/services

# create and mount boot partition
mkdir -p /mnt/boot
mkfs.vfat -F32 $(echo $DISK | cut -f1 -d\ )2
mount -t vfat $(echo $DISK | cut -f1 -d\ )2 /mnt/boot

# Generate initial system configuration
nixos-generate-config --root /mnt

export CRYPTKEY="$(blkid -o export "$DISK1_KEY" | grep "^UUID=")"
export CRYPTKEY="${CRYPTKEY#UUID=*}"

export CRYPTSWAP="$(blkid -o export "$DISK1_SWAP" | grep "^UUID=")"
export CRYPTSWAP="${CRYPTSWAP#UUID=*}"

export RPOOL_PARTUUID="$(blkid -o export $(echo $DISK | cut -f1 -d\ )5 | grep "^PARTUUID=")"
export RPOOL_PARTUUID="${RPOOL_PARTUUID#PARTUUID=*}"

# Import ZFS/boot-specific configuration
sed -i "s|./hardware-configuration.nix|./hardware-configuration.nix ./boot.nix|g" /mnt/etc/nixos/configuration.nix

# Set root password
export rootPwd=$(mkpasswd -m SHA-512 -s "VerySecurePassword")
# Write boot.nix configuration
tee -a /mnt/etc/nixos/boot.nix <<EOF
{ config, pkgs, lib, ... }:

{ boot.supportedFilesystems = [ "zfs" ];
	# Kernel modules needed for mounting LUKS devices in initrd stage
	boot.initrd.availableKernelModules = [ "aesni_intel" "cryptd" ];

	boot.initrd.luks.devices = {
		cryptkey = {
			device = "/dev/disk/by-uuid/$CRYPTKEY";
		};

		cryptswap = {
			device = "/dev/disk/by-uuid/$CRYPTSWAP";
			keyFile = "$KEY_DISK";
			keyFileSize = 64;
		};
	};

	boot.zfs.devNodes = "/dev/disk/by-partuuid/$RPOOL_PARTUUID";
	boot.zfs.forceImportAll = true;

	# ZFS ARC Size 64MB
	boot.kernelParams = [ "zfs.zfs_arc_max=268435456" ];

	networking.hostId = "$(head -c 8 /etc/machine-id)";
	boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;

	boot.loader.grub = {
		enable = true;
		copyKernels = true;
		zfsSupport = true;
		device = "/dev/vda2";
	};

	users.users.root.initialHashedPassword = "$rootPwd";
	users.users.nicoswan = {
          isNormalUser = true;
          description = "Nico Swan";
          extraGroups = [ "networkmanager" "wheel" ];
          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJzDICPeNfXXLIEnf4FEQ5ZGX6REsNEPaeRbyxOh7vVL NicoMacLaptop"
          ];
        };
}
EOF

# Install system and apply configuration
nixos-install -v --show-trace --no-root-passwd --root /mnt

# Unmount filesystems
umount -Rl /mnt
zpool export -a

# Reboot
#:wreboot