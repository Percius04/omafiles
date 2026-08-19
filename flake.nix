{
  description = "Omafiles — a native Qt6 file manager";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forEachSupportedSystem = nixpkgs.lib.genAttrs supportedSystems;
      packagesFor = system: import nixpkgs { inherit system; };
      pythonWithGio = pkgs: pkgs.python3.withPackages (pythonPackages: [ pythonPackages.pygobject3 ]);
      # Plain nixpkgs unzip replaces UTF-8 archive names with question marks.
      unzipWithNls = pkgs: pkgs.unzip.override { enableNLS = true; };
      runtimePackages = pkgs: [
        pkgs.bash
        pkgs.coreutils
        pkgs.fontconfig
        pkgs.gawk
        pkgs.glib
        pkgs.gnugrep
        pkgs.gnused
        pkgs.gnutar
        pkgs.udisks2
        pkgs.util-linux
        pkgs.zip
        (pythonWithGio pkgs)
        (unzipWithNls pkgs)
      ];
      mkOmafiles =
        pkgs:
        let
          selfcheckDesktop = pkgs.writeText "omafiles-selfcheck.desktop" ''
            [Desktop Entry]
            Type=Application
            Name=Omafiles self-check text viewer
            Exec=${pkgs.coreutils}/bin/true %f
            MimeType=text/plain;
          '';
        in
        pkgs.stdenv.mkDerivation {
          pname = "omafiles";
          version = "1.0.0";
          src = ./.;

          strictDeps = true;

          nativeBuildInputs = [
            pkgs.cmake
            pkgs.ninja
            pkgs.pkg-config
            pkgs.qt6.wrapQtAppsHook
            (pythonWithGio pkgs)
          ];

          buildInputs = [
            pkgs.glib
            pkgs.qt6.qt5compat
            pkgs.qt6.qtbase
            pkgs.qt6.qtdeclarative
            pkgs.qt6.qtwayland
            pkgs.qt6.qtwebengine
          ];

          cmakeBuildType = "Release";
          cmakeFlags = [
            "-DOMAFILES_BIN_INSTALL_DIR=${builtins.placeholder "out"}/bin"
            "-DOMAFILES_DATA_INSTALL_DIR=${builtins.placeholder "out"}/share"
            "-DOMAFILES_QML_INSTALL_DIR=${builtins.placeholder "out"}/lib/qt6/qml"
          ];

          postPatch = ''
            patchShebangs scripts
          '';

          doInstallCheck = true;
          nativeInstallCheckInputs = runtimePackages pkgs ++ [
            pkgs.desktop-file-utils
            pkgs.ffmpeg
            pkgs.ffmpegthumbnailer
          ];
          installCheckPhase = ''
            runHook preInstallCheck
            export HOME="$TMPDIR/home"
            export XDG_CACHE_HOME="$HOME/.cache"
            export XDG_CONFIG_HOME="$HOME/.config"
            export XDG_DATA_HOME="$HOME/.local/share"
            export XDG_RUNTIME_DIR="$TMPDIR/runtime"
            export XDG_STATE_HOME="$HOME/.local/state"
            mkdir -p \
              "$XDG_CACHE_HOME" \
              "$XDG_CONFIG_HOME" \
              "$XDG_DATA_HOME/applications" \
              "$XDG_DATA_HOME/Trash/files" \
              "$XDG_DATA_HOME/Trash/info" \
              "$XDG_RUNTIME_DIR" \
              "$XDG_STATE_HOME"
            chmod 700 "$XDG_DATA_HOME/Trash" "$XDG_RUNTIME_DIR"
            install -Dm644 ${selfcheckDesktop} \
              "$XDG_DATA_HOME/applications/omafiles-selfcheck.desktop"
            update-desktop-database "$XDG_DATA_HOME/applications"

            # Force resource resolution through the installed tree. Otherwise
            # the build directory masks omissions from the package output.
            mv ../app/Main.qml ../app/Main.qml.source
            trap 'mv ../app/Main.qml.source ../app/Main.qml' EXIT

            LC_ALL=C.UTF-8 QT_QPA_PLATFORM=offscreen \
              "$out/bin/omafiles" --selfcheck
            runHook postInstallCheck
          '';

          qtWrapperArgs = [
            "--prefix PATH : ${pkgs.lib.makeBinPath (runtimePackages pkgs)}"
            "--set FONTCONFIG_FILE ${pkgs.fontconfig.out}/etc/fonts/fonts.conf"
          ];

          meta = {
            description = "High-performance native Qt6 file manager";
            homepage = "https://github.com/Percius04/omafiles";
            license = pkgs.lib.licenses.mit;
            mainProgram = "omafiles";
            platforms = pkgs.lib.platforms.linux;
          };
        };
    in
    {
      packages = forEachSupportedSystem (
        system:
        let
          omafiles = mkOmafiles (packagesFor system);
        in
        {
          default = omafiles;
          inherit omafiles;
        }
      );

      apps = forEachSupportedSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/omafiles";
          meta = self.packages.${system}.default.meta;
        };
      });

      checks = forEachSupportedSystem (system: {
        package = self.packages.${system}.default;
      });

      devShells = forEachSupportedSystem (
        system:
        let
          pkgs = packagesFor system;
        in
        {
          default = pkgs.mkShell {
            inputsFrom = [ self.packages.${system}.default ];
            packages = runtimePackages pkgs ++ [
              pkgs.clang-tools
              pkgs.gdb
            ];
          };
        }
      );
    };
}
