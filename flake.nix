{
  description = "Unofficial Linux build of the Grok Bot desktop app";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" ];
      upstream = builtins.fromJSON (builtins.readFile ./upstream.json);
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f (import nixpkgs {
          inherit system;
          config.allowUnfree = true;
        }));
    in
    {
      overlays.default = final: prev: {
        grok-bot = final.callPackage ./nix/package.nix { inherit upstream; };
      };

      packages = forAllSystems (pkgs: rec {
        grok-bot = pkgs.callPackage ./nix/package.nix { inherit upstream; };
        default = grok-bot;
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = with pkgs; [ curl python3 p7zip asar nodejs jq ];
        };
      });
    };
}
