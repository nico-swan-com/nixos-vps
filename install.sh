#!/bin/sh
# The disk that will be used
# NOTE: If installing on an nvme drive (ie: /dev/nvme0n1), you'll need to replace all occurrences of ${DISK}# with ${DISK}p# where # is the partition number.
# Don't forget to also replace all occurences of $(echo $DISK | cut -f1 -d\ )# with $(echo $DISK | cut -f1 -d\ )p#
export DISK='/dev/sda' 
export userPwd='$y$j9T$sZlZK2gaQO/GLQPMMjGDS1$uCF3JloZrwTzLsxZuAvkJrw6/Z6ls/jPbkJgO/EqQy1';
export hostname="vm403bfeq";
export hostdomain="cygnus-labs.com";
export username="nicoswan";
export defaultPasswordHash="$userPwd";
export userPublicKey="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJzDICPeNfXXLIEnf4FEQ5ZGX6REsNEPaeRbyxOh7vVL NicoMacLaptop";
export diskDevice="$DISK";



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
   mkpart 'ESP' 1MB 1024MB set 1 esp on \
   mkpart 'swap' 1024MB 4096MB \
   mkpart 'root' 4096MB '100%'

# parted --script --align optimal $DISK \
#    mkpart 'BIOS-boot' 1MB 8MB \
#    mkpart 'ESP' 1MB 1026MB set 2 esp on \
#    mkpart 'swap' 1026MB 4098MB \
#    mkpart 'root' 4098MB '100%'

# Root format and mount
mkfs.ext4 -L root $(echo $DISK | cut -f1 -d\ )3
mount $(echo $DISK | cut -f1 -d\ )3 /mnt

# Swap format and mount
mkswap -L swap $(echo $DISK | cut -f1 -d\ )2
swapon $(echo $DISK | cut -f1 -d\ )2

# create and mount boot partition
mkdir -p /mnt/boot
mkfs.fat -F 32 -n boot $(echo $DISK | cut -f1 -d\ )1
mount -o umask=077 $(echo $DISK | cut -f1 -d\ )1 /mnt/boot
}

create_config() 
{
# Generate initial system configuration
nixos-generate-config --root /mnt
rm /mnt/etc/nixos/configuration.nix
vi /mnt/etc/nixos/hardware-configuration.nix

# Set root password
# Write boot.nix configuration
tee -a /mnt/etc/nixos/configuration.nix <<EOF
{ lib, config, pkgs, ... }:
{

  imports = [ ./hardware-configuration.nix ];

  #Hardware
  
  boot.kernelPackages = pkgs.linuxPackages_latest;
  boot.initrd.availableKernelModules = [
    "ata_piix"
    "uhci_hcd"
    "xen_blkfront"
    "vmw_pvscsi"
    "virtio_net"
    "virtio_pci"
    "virtio_mmio"
    "virtio_blk"
    "virtio_scsi"
    "9p"
    "9pnet_virtio"
  ];
  #boot.initrd.kernelModules = [ "nvme" "kvm-intel" "virtio_balloon" "virtio_console" "virtio_rng" ];
  boot.initrd.kernelModules = [ "nvme" "kvm-intel" "virtio_console" "virtio_rng" ];
  boot.initrd.postDeviceCommands = lib.mkIf (!config.boot.initrd.systemd.enable)
    ''
      # Set the system time from the hardware clock to work around a
      # bug in qemu-kvm > 1.5.2 (where the VM clock is initialised
      # to the *boot time* of the host).
      hwclock -s
    '';

  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;


  nix = {
    settings = {
      # Necessary for using flakes on this system.
      experimental-features = "nix-command flakes";

      # Add needed system-features to the nix daemon
      # Starting with Nix 2.19, this will be automatic
      system-features = [
        "nixos-test"
        "kvm"
      ];

      auto-optimise-store = true;
    };

    extraOptions = ''
      experimental-features = nix-command flakes
    '';
  };

  # Bootloader.
  boot.loader.grub = {
    enable = true;
    device = "$diskDevice";
    memtest86.enable = true;
  };

  # Enable networking
  networking.networkmanager.enable = true;
  networking.useDHCP = false; # lib.mkDefault true;
  networking.interfaces.ens18.ipv4.addresses = [{
    address = "102.135.163.95";
    prefixLength = 24;
  }];
  networking.defaultGateway = "102.135.163.1";
  networking.nameservers = [ "1.1.1.1" "1.0.0.1" ];
  networking.hostName = "$hostname"; # Define your hostname.
  networking.domain = "$hostdomain";

  # Set your time zone.
  time.timeZone = "Africa/Johannesburg";

  # Select internationalisation properties.
  i18n.defaultLocale = "en_ZA.UTF-8";

  # Set /etc/zshrc
  programs.zsh.enable = true;

  # Default users
  users.mutableUsers = false;
  users.users.root.initialHashedPassword = "$defaultPasswordHash";
  users.users.$username = {
    isNormalUser = true;
    extraGroups = [ "networkmanager" "wheel" ];
    hashedPassword = "$defaultPasswordHash";
    openssh.authorizedKeys.keys = [ "$userPublicKey" ];
    shell = pkgs.zsh; # default shell
  };

  users.users.vmbfeqcy = {
    isNormalUser = true;
    hashedPassword = "$defaultPasswordHash";
    openssh.authorizedKeys.keys = [ "$userPublicKey" ];
  };

  # Enable automatic login for the user.
  services.getty.autologinUser = "$username";

  # Allow unfree packages
  nixpkgs.config.allowUnfree = true;

  # List packages installed in system profile. To search, run:
  # $ nix search wget
  environment.systemPackages = with pkgs; [ vim ];

  # Enable the OpenSSH daemon.
  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "yes";
  };

  # Quemu guest agent
  services.qemuGuest.enable = true;

  networking.firewall.enable = false;

  # Required for remote vscode
  # https://nixos.wiki/wiki/Visual_Studio_Code
  programs.nix-ld.enable = true;

  system.stateVersion = "24.05";
}
EOF

vi /mnt/etc/nixos/configuration.nix

}


install_nixos()
{
export NIX_CHANNEL=nixos-24.05
# Install system and apply configuration
nixos-install -v --show-trace --no-root-passwd --root /mnt

}

reboot_now() 
{
# Unmount filesystems
umount -Rl /mnt
zpool export -a

# Reboot
#reboot
}

create_partitions
create_config
install_nixos
reboot_now