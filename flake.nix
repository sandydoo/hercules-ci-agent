{
  description = "Hercules CI Agent";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-20.03";
  inputs.flake-compat.url = "github:edolstra/flake-compat";
  inputs.flake-compat.flake = false;
  inputs.pre-commit-hooks-nix.url = "github:cachix/pre-commit-hooks.nix";
  inputs.pre-commit-hooks-nix.flake = false;

  outputs = inputs@{ self, nixpkgs, ... }:
    let
      lib = nixpkgs.lib;
      filterMeta = nixpkgs.lib.filterAttrs (k: v: k != "meta" && k != "recurseForDerivations");
      dimension = _name: attrs: f: lib.mapAttrs f attrs;

      defaultTarget = allTargets."nixos-20_03";
      testSuiteTarget = defaultTarget;

      allTargets =
        dimension "Nixpkgs version"
          {
            "nixos-20_03" = {
              nixpkgsSource = nixpkgs;
            };
            # "nixos-unstable" = {
            #   nixpkgsSource = "nixos-unstable";
            # };
          }
          (
            _name: { nixpkgsSource }:
              dimension "System"
                {
                  "aarch64-linux" = { enable = true; };
                  "x86_64-linux" = { enable = true; };
                  "x86_64-darwin" = { enable = true; };
                }
                (
                  system: { enable }:

                    lib.optionalAttrs enable (
                      let
                        pkgs =
                          import nixpkgsSource {
                            overlays = [ (import ./nix/overlay.nix inputs) dev-and-test-overlay ];
                            config = { };
                            inherit system;
                          };
                        dev-and-test-overlay =
                          self: pkgs:
                          {
                            testSuitePkgs = testSuiteTarget.${system};
                            devTools =
                              {
                                inherit (self.hercules-ci-agent-packages.internal.haskellPackages)
                                  ghc
                                  ghcid
                                  stack
                                  ;
                                inherit (pkgs)
                                  jq
                                  cabal2nix
                                  nix-prefetch-git
                                  niv
                                  ;
                                inherit pkgs;
                              };
                          };
                      in
                      pkgs.recurseIntoAttrs {
                        internal.pkgs = pkgs;
                        inherit (pkgs.hercules-ci-agent-packages)
                          hercules-ci-cli
                          ;
                        inherit (pkgs)
                          hercules-ci-agent
                          hercules-ci-agent-packages
                          devTools
                          toTOML-test
                          pre-commit-check
                          ;
                      }
                    )
                )
          );

    in
    {
      # non-standard attribute
      ciChecks = allTargets;

      internal.pkgs = lib.mapAttrs (_sys: target: target.internal.pkgs) defaultTarget;

      packages =
        nixpkgs.lib.mapAttrs
          (
            k: v:
              {
                inherit (filterMeta v)
                  hercules-ci-agent
                  hercules-ci-cli
                  ;
              }
          )
          (filterMeta defaultTarget);

      overlay =
        final: prev: (import ./nix/overlay.nix inputs) final prev;

      # TODO
      # nixosModules.agent-service = { imports = [ ./module.nix ]; };
      nixosModules.agent-profile = { imports = [ ./module.nix ]; };

      defaultApp = lib.mapAttrs (k: v: v.hercules-ci-cli) self.packages;

      defaultTemplate = self.templates.nixos;
      templates = {
        nixos = {
          path = ./templates/nixos;
          description = "A NixOS configuration with Hercules CI Agent";
        };
      };

      devShell = lib.mapAttrs
        (
          k: { internal, devTools, hercules-ci-agent-packages, ... }:
            internal.pkgs.mkShell {
              buildInputs =
                [
                  devTools.niv
                  devTools.stack
                  devTools.ghcid
                  devTools.jq
                  devTools.cabal2nix
                  devTools.nix-prefetch-git
                  hercules-ci-agent-packages.internal.haskellPackages.ghc
                  hercules-ci-agent-packages.internal.haskellPackages.ghcide
                ];
              inherit (hercules-ci-agent-packages.pre-commit-check) shellHook;
            }
        )
        defaultTarget;
    };
}
