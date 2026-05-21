{
  description = "skk.koplugin — dev shell with Lua 5.1 + luacheck";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "x86_64-darwin" "aarch64-darwin" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in {
      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          packages = [
            pkgs.lua5_1                   # runtime for tests (Lua 5.1, same as LuaJIT compat)
            pkgs.lua51Packages.luacheck   # static analysis
          ];
          shellHook = ''
            echo "$(lua -v 2>&1)"
            echo "luacheck $(luacheck --version)"
          '';
        };
      });
    };
}
