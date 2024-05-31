# The disk that will be used
# NOTE: If installing on an nvme drive (ie: /dev/nvme0n1), you'll need to replace all occurrences of ${DISK}# with ${DISK}p# where # is the partition number.
# Don't forget to also replace all occurences of $(echo $DISK | cut -f1 -d\ )# with $(echo $DISK | cut -f1 -d\ )p#
export DISK='/dev/sda' 

# we use parted here since it does a good job with adding BIOS protective MBR to GPT disk
# since we are booting in BIOS mode, we get a max of 4 primary partitions
# BIOS MBR partition (8MB)
# /boot partition (1GB)
# swap partition (3GB)
# XFS root partition (Remaining space)
# NOTE: Make the XFS root partition your last partition, so that if you resize the disk it will be easy to get XFS to use the extra space
parted --script $DISK mklabel gpt
parted --script --align optimal $DISK -- mklabel gpt mkpart 'BIOS-boot' 1MB 8MB set 1 bios_grub on \
   mkpart 'boot' 8MB 1026MB \
   mkpart 'swap' 1026MB 4098MB \
   mkpart 'nixos' 4098MB '100%'

mkfs.xfs -L nixos $(echo $DISK | cut -f1 -d\ )3
mkswap -L swap $(echo $DISK | cut -f1 -d\ )2


# Mount root ZFS dataset
mount -t xfs /dev/sda3 /mnt

# create and mount boot partition
mkdir -p /mnt/boot
mkfs.vfat -F32 $(echo $DISK | cut -f1 -d\ )2
mount -t vfat $(echo $DISK | cut -f1 -d\ )2 /mnt/boot

# Generate initial system configuration
nixos-generate-config --root /mnt

# Disable xserver
sed -i "s|services.xserver|# services.xserver|g" /mnt/etc/nixos/configuration.nix

# Import ZFS/boot-specific configuration
sed -i "s|./hardware-configuration.nix|./hardware-configuration.nix ./boot.nix ./networking.nix ./users.nix ./nix-config.nix|g" /mnt/etc/nixos/configuration.nix

# Disable dhcp
sed -i "s|networking.useDHCP|# networking.useDHCP|g" /mnt/etc/nixos/hardware-configuration.nix

# Set root password
export rootPwd=$(mkpasswd -m SHA-512 -s "VerySecurePassword")
# Write boot.nix configuration
tee -a /mnt/etc/nixos/boot.nix <<EOF
{ config, pkgs, lib, ... }:
{


    boot.loader.grub = {
      enable = true;
      copyKernels = true;
      zfsSupport = true;
      efiSupport = true;
      efiInstallAsRemovable = true;
      mirroredBoots = [
        { devices = [ "nodev" "$DISK" ]; path = "/boot"; }
      ];
  };
}
EOF

tee -a /mnt/etc/nixos/users.nix <<EOF
{ config, pkgs, lib, ... }:
{
    users.users.root.initialHashedPassword = "$rootPwd";
    users.users.nicoswan = {
          isNormalUser = true;
          description = "Nico Swan";
          extraGroups = [ "networkmanager" "wheel" ];

          openssh.authorizedKeys.keys = [
            "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJzDICPeNfXXLIEnf4FEQ5ZGX6REsNEPaeRbyxOh7vVL NicoMacLaptop"
          ];
        };

    # Enable the OpenSSH daemon.
    services.openssh = {
      enable = true;
      settings.PasswordAuthentication = true;
      settings.PermitRootLogin = "yes";
    };
}
EOF

tee -a /mnt/etc/nixos/networking.nix <<EOF
{ config, pkgs, lib, ... }:
{
    
    networking.useDHCP = lib.mkDefault false;
    networking.interfaces.ens18.ipv4.addresses = [{
       address = "102.135.163.95";
       prefixLength = 24;
    }];
    networking.defaultGateway = "102.135.163.1";
    networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];

}
EOF

tee -a /mnt/etc/nixos/nix-config.nix <<EOF
{ config, pkgs, lib, ... }:
{

  services.qemuGuest.enable = true;	

  # Set your time zone.
  time.timeZone = "Africa/Johannesburg";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_ZA.UTF-8";

  # Configure keymap in X11
  services.xserver = {
    xkb.layout = "za";
    xkb.variant = "";
  };    
    
  nix = {
    settings = {
      # Necessary for using flakes on this system.
      experimental-features = "nix-command flakes";
    };

    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

}
EOF


echo "Press any key to start installation"
read

# Install system and apply configuration
nixos-install -v --show-trace --no-root-passwd --root /mnt

echo "Press any key to reboot"
read

# Unmount filesystems
umount -Rl /mnt
zpool export -a

# Reboot
reboot