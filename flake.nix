{
  description = "DankMaterialShell bar pill showing the countdown to your next upcoming calendar event (via khal).";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = nixpkgs.legacyPackages.${system};
      in {
        # Plain plugin layout: plugin.json + a single QML file. DMS's
        # plugin loader picks them up directly from the directory; the
        # derivation just copies them into shape.
        packages.default = pkgs.runCommand "dms-meeting-pill" {} ''
          mkdir -p $out
          cp ${./plugin.json} $out/plugin.json
          cp ${./MeetingWidget.qml} $out/MeetingWidget.qml
        '';

        checks.plugin-json-valid = pkgs.runCommand "plugin-json-valid" {} ''
          ${pkgs.jq}/bin/jq -e '.id and .name and .component' ${./plugin.json} > /dev/null
          touch $out
        '';
      }
    );
}
