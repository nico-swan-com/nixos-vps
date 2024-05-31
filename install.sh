#!/bin/sh
# The disk that will be used
# NOTE: If installing on an nvme drive (ie: /dev/nvme0n1), you'll need to replace all occurrences of ${DISK}# with ${DISK}p# where # is the partition number.
# Don't forget to also replace all occurences of $(echo $DISK | cut -f1 -d\ )# with $(echo $DISK | cut -f1 -d\ )p#
export DISK='/dev/sda' 



create_partitions()
{
# we use parted here since it does a good job with adding BIOS protective MBR to GPT disk
# since we are booting in BIOS mode, we get a max of 4 primary partitions
# BIOS MBR partition (8MB)
# /boot partition (1GB)
# swap partition (3GB)
# XFS root partition (Remaining space)
# NOTE: Make the XFS root partition your last partition, so that if you resize the disk it will be easy to get XFS to use the extra space
parted --script $DISK mklabel gpt
parted --script --align optimal $DISK \
   mkpart 'BIOS-boot' 1MB 8MB set 1 esp on \
   mkpart 'ESP' 8MB 1026MB \
   mkpart 'swap' 1026MB 4098MB \
   mkpart 'root' 4098MB '100%'

# Root format and mount
mkfs.ext4 -L root $(echo $DISK | cut -f1 -d\ )4
mount $(echo $DISK | cut -f1 -d\ )4 /mnt

# Swap format and mount
mkswap -L swap $(echo $DISK | cut -f1 -d\ )3
swapon $(echo $DISK | cut -f1 -d\ )3

# create and mount boot partition
mkdir -p /mnt/boot
mkfs.fat -F 32 -n boot $(echo $DISK | cut -f1 -d\ )2
mount -o umask=077 /dev/disk/by-label/boot /mnt/boot
}

create_config() 
{
# Generate initial system configuration
nixos-generate-config --root /mnt

# Disable xserver
sed -i "s|services.xserver|# services.xserver|g" /mnt/etc/nixos/configuration.nix

# Import ZFS/boot-specific configuration
sed -i "s|./hardware-configuration.nix|./hardware-configuration.nix ./boot.nix ./networking.nix ./users.nix ./nix-config.nix|g" /mnt/etc/nixos/configuration.nix

# Disable dhcp
sed -i "s|networking.useDHCP|# networking.useDHCP|g" /mnt/etc/nixos/hardware-configuration.nix

# Set root password
export userPwd='$y$j9T$sZlZK2gaQO/GLQPMMjGDS1$uCF3JloZrwTzLsxZuAvkJrw6/Z6ls/jPbkJgO/EqQy1';
# Write boot.nix configuration
tee -a /mnt/etc/nixos/boot.nix <<EOF
{ config, pkgs, lib, ... }:
{

  # My Initrd config, enable ZSTD compression and use systemd-based stage 1 boot
  boot.initrd = {
    compressor = "zstd";
    compressorArgs = [ "-19" "-T0" ];
    systemd.enable = true;
  };

  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.loader.systemd-boot.enable = true; 
  # boot.loader.grub = {
  #   enable = true;
  #   efiSupport = true;
  #   efiInstallAsRemovable = true;
  #   mirroredBoots = [
  #     { devices = [ "nodev" "$DISK" ]; path = "/boot"; }
  #   ];
  # };
}
EOF

tee -a /mnt/etc/nixos/users.nix <<EOF
{ config, pkgs, lib, ... }:
{
    users.mutableUsers = false;
    users.users.root.initialHashedPassword = "$userPwd";
    users.users.nicoswan = {
          isNormalUser = true;
          description = "Nico Swan";
          extraGroups = [ "networkmanager" "wheel" ];
          hashedPassword = "$userPwd";
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
    
  # Disable NixOS's builtin firewall
  networking.firewall.enable = false;

  # Hostname, can be set as you wish
  networking.hostName = "vm403bfeq";

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


  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [
    vim
    btop
  ];
}
EOF
}


install_nixos()
{
echo "Press any key to start installation"
read

# Install system and apply configuration
nixos-install -v --show-trace --no-root-passwd --root /mnt

echo "Press any key to reboot"
read

}

reboot_now() 
{
# Unmount filesystems
umount -Rl /mnt
zpool export -a

# Reboot
reboot
}

create_partitions
create_config
#install_nixos
#reboot_now