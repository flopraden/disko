{ pkgs ? (import <nixpkgs> { })
, makeTest ? import <nixpkgs/nixos/tests/make-test-python.nix>
, eval-config ? import <nixpkgs/nixos/lib/eval-config.nix>
, ...
}:
{
  makeDiskoTest =
    { disko-config
    , extraTestScript ? ""
    , bootCommands ? ""
    , extraConfig ? { }
    , grub-devices ? [ "nodev" ]
    , efi ? true
    , enableOCR ? false
    }:
    let
      lib = pkgs.lib;
      makeTest' = args:
        makeTest args {
          inherit pkgs;
          inherit (pkgs) system;
        };
      disks = [ "/dev/vda" "/dev/vdb" "/dev/vdc" "/dev/vdd" "/dev/vde" "/dev/vdf" ];
      tsp-create = pkgs.writeScript "create" ((pkgs.callPackage ../. { }).create (disko-config { disks = builtins.tail disks; }));
      tsp-mount = pkgs.writeScript "mount" ((pkgs.callPackage ../. { }).mount (disko-config { disks = builtins.tail disks; }));
      tsp-config = (pkgs.callPackage ../. { }).config (disko-config { inherit disks; });
      num-disks = builtins.length (lib.attrNames (disko-config {}).disk);
      installed-system = { modulesPath, ... }: {
        imports = [
          tsp-config
          (modulesPath + "/testing/test-instrumentation.nix")
          (modulesPath + "/profiles/qemu-guest.nix")
          (modulesPath + "/profiles/minimal.nix")
          extraConfig
        ];
        fileSystems."/nix/store" = {
          device = "nix-store";
          fsType = "9p";
          neededForBoot = true;
          options = [ "trans=virtio" "version=9p2000.L" "cache=loose" ];
        };
        documentation.enable = false;
        hardware.enableAllFirmware = lib.mkForce false;
        networking.hostId = "8425e349"; # from profiles/base.nix, needed for zfs
        boot.kernelParams = lib.mkAfter [ "console=tty0" ]; # needed to have serial interaction during boot
        boot.zfs.devNodes = "/dev/disk/by-uuid"; # needed because /dev/disk/by-id is empty in qemu-vms

        boot.consoleLogLevel = lib.mkForce 100;
        boot.loader.grub = {
          devices = grub-devices;
          efiSupport = efi;
          efiInstallAsRemovable = efi;
        };
      };
      installedTopLevel = (eval-config {
        modules = [ installed-system ];
        system = "x86_64-linux";
      }).config.system.build.toplevel;
    in
    makeTest' {
      name = "disko";

      inherit enableOCR;
      nodes.machine = { config, pkgs, modulesPath, ... }: {
        imports = [
          (modulesPath + "/profiles/base.nix")
          (modulesPath + "/profiles/minimal.nix")
          extraConfig
        ];

        # speed-up eval
        documentation.enable = false;

        nix.settings = {
          substituters = lib.mkForce [];
          hashed-mirrors = null;
          connect-timeout = 1;
        };

        virtualisation.emptyDiskImages = builtins.genList (_: 4096) num-disks;
      };

      testScript = ''
        def disks(oldmachine, num_disks):
            disk_flags = ""
            for i in range(num_disks):
                disk_flags += f' -drive file={oldmachine.state_dir}/empty{i}.qcow2,id=drive{i + 1},if=none,index={i + 1},werror=report'
                disk_flags += f' -device virtio-blk-pci,drive=drive{i + 1}'
            return disk_flags
        def create_test_machine(oldmachine=None, args={}): # taken from <nixpkgs/nixos/tests/installer.nix>
            machine = create_machine({
              "qemuFlags": "-cpu max -m 1024 -virtfs local,path=/nix/store,security_model=none,mount_tag=nix-store" + disks(oldmachine, ${toString num-disks}),
              ${lib.optionalString efi ''"bios": "${pkgs.OVMF.fd}/FV/OVMF.fd",''}
            } | args)
            driver.machines.append(machine)
            return machine

        machine.start()
        machine.succeed("echo -n 'secret' > /tmp/secret.key")
        machine.succeed("${tsp-create}")
        machine.succeed("${tsp-mount}")
        machine.succeed("${tsp-mount}") # verify that the command is idempotent

        # mount nix-store in /mnt
        machine.succeed("mkdir -p /mnt/nix/store")
        machine.succeed("mount --bind /nix/store /mnt/nix/store")

        machine.succeed("nix-store --load-db < ${pkgs.closureInfo {rootPaths = [installedTopLevel];}}/registration")

        # fix "this is not a NixOS installation"
        machine.succeed("mkdir -p /mnt/etc")
        machine.succeed("touch /mnt/etc/NIXOS")

        machine.succeed("mkdir -p /mnt/nix/var/nix/profiles")
        machine.succeed("nix-env -p /mnt/nix/var/nix/profiles/system --set ${installedTopLevel}")
        machine.succeed("NIXOS_INSTALL_BOOTLOADER=1 nixos-enter --root /mnt -- ${installedTopLevel}/bin/switch-to-configuration boot")
        machine.succeed("sync")
        machine.shutdown()

        machine = create_test_machine(oldmachine=machine, args={ "name": "booted_machine" })
        machine.start()
        ${bootCommands}
        machine.wait_for_unit("local-fs.target")
        ${extraTestScript}
      '';
    };
}
