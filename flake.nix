{
  description = "GO devenv for development";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";

      pkgs = import nixpkgs {
        inherit system;

        config = {
          allowUnfreePredicate =
            pkg:
            builtins.elem (pkgs.lib.getName pkg) [
              "google-chrome"
            ];
        };
      };
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = with pkgs; [
          nixfmt
          beam27Packages.erlang
          beam27Packages.elixir
          beam27Packages.elixir-ls
          nodejs
          yarn
          inotify-tools
          tree
          chromedriver
          google-chrome
          playwright-test
        ];

        shellHook = ''
          export TAILWINDCSS_PATH="${pkgs.lib.getExe pkgs.tailwindcss_4}"
          export CHROME_PATH="${pkgs.google-chrome}/bin/google-chrome-stable"
          export CHROMEDRIVER_PATH="${pkgs.chromedriver}/bin/chromedriver"
          export PLAYWRIGHT_BROWSERS_PATH=${pkgs.playwright-driver.browsers}
        '';
      };
    };
}
