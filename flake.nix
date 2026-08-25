{
  description = "Talos homelab cluster management environment";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-parts.url = "github:hercules-ci/flake-parts";
  };

  outputs = inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];

      perSystem = { pkgs, ... }: {
        devShells.default = pkgs.mkShell {
          packages = with pkgs; [
            # Talos
            talosctl

            # Kubernetes
            kubectl
            kubernetes-helm
            kustomize
            fluxcd

            # YAML / JSON
            yq-go
            jq

            # Secret management
            sops
            age

            # General tooling
            curl
            openssl
            git
            coreutils
          ];

          shellHook = ''
            export CLUSTER_ROOT="$PWD"
            export PATH="$CLUSTER_ROOT/bin:$PATH"

            export TALOSCONFIG="$CLUSTER_ROOT/credentials/talosconfig"
            export KUBECONFIG="$CLUSTER_ROOT/credentials/kubeconfig"

            if [ -f "$CLUSTER_ROOT/cluster.env" ]; then
              source "$CLUSTER_ROOT/cluster.env"
            fi

            umask 077

            echo
            echo "Talos homelab management shell"
            echo "Cluster root: $CLUSTER_ROOT"
            echo "TALOSCONFIG:  $TALOSCONFIG"
            echo "KUBECONFIG:   $KUBECONFIG"
            echo
          '';
        };
      };
    };
}
