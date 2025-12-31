{ lib }:

let
  # ============ DISCOVERY HELPERS ============

  # Check if name looks like an architecture (contains a dash)
  isArch = name: builtins.match ".*-.*" name != null;

  # Parse "user@hostname" format
  parseHomeName = name:
    let parts = lib.splitString "@" name;
    in if builtins.length parts == 2
       then { user = builtins.elemAt parts 0; hostname = builtins.elemAt parts 1; }
       else { user = name; hostname = "default"; };

  # Discover systems from systems/{arch}/{hostname}/
  discoverSystems = dir:
    let
      archDirs = builtins.readDir dir;
      validArchs = lib.filterAttrs (n: v: v == "directory" && isArch n) archDirs;

      processArch = arch:
        let
          archPath = dir + "/${arch}";
          hosts = builtins.readDir archPath;
          validHosts = lib.filterAttrs (n: v: v == "directory" && n != "archive") hosts;
        in
        lib.mapAttrs (hostname: _: {
          inherit arch hostname;
          path = archPath + "/${hostname}";
          isDarwin = lib.hasSuffix "-darwin" arch;
        }) validHosts;
    in
    lib.foldl' (acc: arch: acc // processArch arch) {} (builtins.attrNames validArchs);

  # Discover homes from homes/{arch}/{user}@{hostname}/
  discoverHomes = dir:
    let
      archDirs = builtins.readDir dir;
      validArchs = lib.filterAttrs (n: v: v == "directory" && isArch n) archDirs;

      processArch = arch:
        let
          archPath = dir + "/${arch}";
          homes = builtins.readDir archPath;
          validHomes = lib.filterAttrs (n: v: v == "directory") homes;
        in
        lib.mapAttrs' (name: _:
          let parsed = parseHomeName name;
          in lib.nameValuePair name {
            inherit arch name;
            inherit (parsed) user hostname;
            path = archPath + "/${name}";
          }
        ) validHomes;
    in
    lib.foldl' (acc: arch: acc // processArch arch) {} (builtins.attrNames validArchs);

  # Discover modules from modules/{type}/*/
  discoverModules = dir: type:
    let
      typePath = dir + "/${type}";
      exists = builtins.pathExists typePath;
      modules = if exists then builtins.readDir typePath else {};
      validModules = lib.filterAttrs (n: v: v == "directory") modules;
    in
    map (name: typePath + "/${name}") (builtins.attrNames validModules);

in {
  inherit isArch parseHomeName discoverSystems discoverHomes discoverModules;

  # ============ MAIN MKFLAKE FUNCTION ============

  mkFlake = {
    # Required
    inputs,
    src,  # Path to flake root (usually ./.)

    # Optional configuration
    overlays ? [],

    # Module configuration
    commonNixosModules ? [],
    commonDarwinModules ? [],
    commonHomeModules ? [],

    # Directory names (relative to src)
    systemsDir ? "systems",
    homesDir ? "homes",
    modulesDir ? "modules",

    # Extra specialArgs to pass to all configurations
    extraSpecialArgs ? {},

    # Optional: custom lib extensions
    customLib ? {},
  }:
  let
    inherit (inputs) nixpkgs home-manager;
    darwin = inputs.darwin or inputs.nix-darwin or null;

    # Extended lib with custom functions
    extendedLib = lib // customLib;

    # ============ DISCOVERY ============

    systemsPath = src + "/${systemsDir}";
    homesPath = src + "/${homesDir}";
    modulesPath = src + "/${modulesDir}";

    discoveredSystems =
      if builtins.pathExists systemsPath
      then discoverSystems systemsPath
      else {};

    discoveredHomes =
      if builtins.pathExists homesPath
      then discoverHomes homesPath
      else {};

    discoveredNixosModules = discoverModules modulesPath "nixos";
    discoveredDarwinModules = discoverModules modulesPath "darwin";

    # ============ PKGS & SPECIAL ARGS ============

    mkPkgs = arch: import nixpkgs {
      localSystem = arch;
      config.allowUnfree = true;
      inherit overlays;
    };

    mkSpecialArgs = { arch, hostname, format }:
      {
        inherit inputs;
        system = arch;
        target = "${arch}-${format}";
        inherit format;
        virtual = false;
        systems = discoveredSystems;
      } // extraSpecialArgs;

    # ============ HOME WIRING ============

    # Find homes matching a specific system
    homesForSystem = arch: hostname:
      lib.filterAttrs (name: home:
        home.arch == arch && (home.hostname == hostname || home.hostname == "default")
      ) discoveredHomes;

    # Get selected homes for a system (used by Darwin and for user defs)
    getSelectedHomes = { arch, hostname }:
      let
        matching = homesForSystem arch hostname;
        # Group by user, prefer specific home over default
        byUser = lib.groupBy (home: home.user) (lib.attrValues matching);
        selectedHomes = lib.mapAttrs (user: homeList:
          let
            specific = lib.findFirst (h: h.hostname == hostname) null homeList;
            default = lib.findFirst (h: h.hostname == "default") null homeList;
          in
          if specific != null then specific else default
        ) byUser;
      in
      lib.filterAttrs (n: v: v != null) selectedHomes;

    # Build home-manager.users attrset (unconditional, for Darwin)
    mkHomeUsers = homes:
      lib.mapAttrs (user: home: { ... }: {
        imports = [ home.path ];
      }) homes;

    # NixOS module that applies homes - only applies specific hostname matches
    # @default homes are skipped for NixOS (they can still be used standalone)
    mkHomeUsersModule = { arch, hostname, specialArgs }:
      let
        matching = homesForSystem arch hostname;
        # Only use homes with specific hostname match, not @default
        specificHomes = lib.filterAttrs (name: home:
          home.hostname == hostname
        ) matching;
        # Group by user, in case there are multiple (shouldn't happen with specific matching)
        byUser = lib.groupBy (home: home.user) (lib.attrValues specificHomes);
        selectedHomes = lib.mapAttrs (user: homeList:
          lib.head homeList  # Take first match
        ) byUser;
      in
      { config, ... }: {
        home-manager.users = lib.mapAttrs (user: home: { ... }: {
          imports = [ home.path ];
        }) selectedHomes;
      };

    # ============ SYSTEM BUILDERS ============

    mkNixosHost = hostname: { arch, path, ... }:
      let
        specialArgs = mkSpecialArgs { inherit arch hostname; format = "nixos"; };
        homeUsersModule = mkHomeUsersModule { inherit arch hostname specialArgs; };
      in
      nixpkgs.lib.nixosSystem {
        specialArgs = specialArgs // { lib = extendedLib; };
        modules = [
          {
            nixpkgs.hostPlatform = arch;
            nixpkgs.overlays = overlays;
            nixpkgs.config.allowUnfree = true;
          }
        ] ++ commonNixosModules ++ discoveredNixosModules ++ [
          path
          {
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "backup";
            home-manager.sharedModules = commonHomeModules;
            home-manager.extraSpecialArgs = specialArgs // {
              home = arch;
              target = "${arch}-home";
              format = "home";
              host = hostname;
            };
          }
          homeUsersModule
        ];
      };

    mkDarwinHost = hostname: { arch, path, ... }:
      let
        specialArgs = mkSpecialArgs { inherit arch hostname; format = "darwin"; };
        selectedHomes = getSelectedHomes { inherit arch hostname; };
        homeUsers = mkHomeUsers selectedHomes;
        userDefs = lib.mapAttrs (user: _: {
          home = if lib.hasPrefix "aarch64-darwin" arch || lib.hasPrefix "x86_64-darwin" arch
                 then "/Users/${user}"
                 else "/home/${user}";
        }) selectedHomes;
      in
      assert darwin != null || throw "mkFlake: darwin/nix-darwin input required for Darwin systems";
      darwin.lib.darwinSystem {
        specialArgs = specialArgs // { lib = extendedLib; };
        modules = [
          {
            nixpkgs.hostPlatform = arch;
            nixpkgs.overlays = overlays;
            nixpkgs.config.allowUnfree = true;
          }
        ] ++ commonDarwinModules ++ discoveredDarwinModules ++ [
          path
          {
            users.users = userDefs;
            home-manager.useGlobalPkgs = true;
            home-manager.useUserPackages = true;
            home-manager.backupFileExtension = "backup";
            home-manager.sharedModules = commonHomeModules;
            home-manager.extraSpecialArgs = specialArgs // {
              home = arch;
              target = "${arch}-home";
              format = "home";
              host = hostname;
            };
            home-manager.users = homeUsers;
          }
        ];
      };

    # ============ BUILD CONFIGURATIONS ============

    nixosSystems = lib.filterAttrs (n: v: !v.isDarwin) discoveredSystems;
    darwinSystems = lib.filterAttrs (n: v: v.isDarwin) discoveredSystems;

    nixosConfigurations = lib.mapAttrs mkNixosHost nixosSystems;
    darwinConfigurations = lib.mapAttrs mkDarwinHost darwinSystems;

    # Standalone home configurations (require pkgs directly, not via module system)
    homeConfigurations = lib.mapAttrs' (name: home:
      let
        pkgs = mkPkgs home.arch;
        specialArgs = mkSpecialArgs {
          arch = home.arch;
          hostname = home.hostname;
          format = "home";
        } // {
          home = home.arch;
          host = home.hostname;
        };
      in
      lib.nameValuePair name (home-manager.lib.homeManagerConfiguration {
        inherit pkgs;
        extraSpecialArgs = specialArgs;
        modules = commonHomeModules ++ [ home.path ];
      })
    ) discoveredHomes;

  in {
    inherit nixosConfigurations darwinConfigurations homeConfigurations;

    # Expose discovered items for introspection
    _internal = {
      inherit discoveredSystems discoveredHomes;
      inherit discoveredNixosModules discoveredDarwinModules;
    };
  };
}
