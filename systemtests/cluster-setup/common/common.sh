#!/usr/bin/env bash
# Shared utilities for cluster-setup/{kind,minikube}. Source, don't execute.

OS_NAME="$(uname -s)"

# The only OS-conditional behavior left after unifying with
# systemtests/scripts/setup-minikube.sh is local exposure (reaching the
# cluster's ingress/registry from the host): Linux can reach the
# minikube/kind node directly; macOS's container engines run inside a
# hidden VM and can't. NEEDS_LOCAL_PORT_FORWARD is that one switch.
case "${OS_NAME}" in
  Darwin) NEEDS_LOCAL_PORT_FORWARD=true ;;
  Linux)  NEEDS_LOCAL_PORT_FORWARD=false ;;
  *)
    echo "Unsupported OS_NAME=${OS_NAME} (expected 'Darwin' or 'Linux')" >&2
    exit 1
    ;;
esac

# Podman machine sizing (only relevant on macOS, where podman needs a VM to
# run containers at all — native Linux podman doesn't). Defaults to (host
# CPUs - 1) and (host memory - 4GB headroom) so the host itself isn't
# starved; override with PODMAN_MACHINE_CPUS/PODMAN_MACHINE_MEMORY (MB).
# Portable: prefers Linux-native tools (nproc, /proc/meminfo), falls back
# to macOS's sysctl.
detect_default_cpus() {
  local total
  if command -v nproc >/dev/null 2>&1; then
    total=$(nproc)
  else
    total=$(sysctl -n hw.ncpu)
  fi
  if [ "${total}" -gt 1 ]; then
    echo $(( total - 1 ))
  else
    echo "${total}"
  fi
}

detect_default_memory_mb() {
  local total_mb headroom_mb=4096
  if [ -r /proc/meminfo ]; then
    total_mb=$(( $(awk '/^MemTotal:/ {print $2}' /proc/meminfo) / 1024 ))
  else
    total_mb=$(( $(sysctl -n hw.memsize) / 1024 / 1024 ))
  fi
  if [ "${total_mb}" -gt "${headroom_mb}" ]; then
    echo $(( total_mb - headroom_mb ))
  else
    echo "${total_mb}"
  fi
}

PODMAN_MACHINE_CPUS="${PODMAN_MACHINE_CPUS:-$(detect_default_cpus)}"
PODMAN_MACHINE_MEMORY="${PODMAN_MACHINE_MEMORY:-$(detect_default_memory_mb)}"

# Checks whether a command is available in PATH; if not, runs the given
# installer function. Generic by design — callers provide their own
# tool-specific installer (see install_skopeo below, or minikube/env.sh's
# install_minikube).
ensure_installed() {
  local bin="$1" installer="$2"
  if command -v "${bin}" >/dev/null 2>&1; then
    return 0
  fi
  echo "'${bin}' not found in PATH, installing..."
  "${installer}"
}

# Installs kubectl — every script here calls it directly. GitHub's Linux
# runners ship it, macOS runners don't.
install_kubectl() {
  local arch
  case "${OS_NAME}" in
    Darwin)
      brew install kubernetes-cli
      ;;
    Linux)
      case "$(uname -m)" in
        arm64|aarch64) arch=arm64 ;;
        x86_64|amd64)  arch=amd64 ;;
        *) echo "Unsupported architecture for kubectl auto-install: $(uname -m)." >&2; exit 1 ;;
      esac
      curl -Lo /tmp/kubectl "https://dl.k8s.io/release/$(curl -Ls https://dl.k8s.io/release/stable.txt)/bin/linux/${arch}/kubectl"
      chmod +x /tmp/kubectl
      sudo mv /tmp/kubectl /usr/local/bin/kubectl
      ;;
  esac
}

ensure_installed kubectl install_kubectl

# Installs kind — only needed by kind/*.sh. GitHub's Linux runners ship it;
# macOS runners don't.
install_kind() {
  case "${OS_NAME}" in
    Darwin) brew install kind ;;
    *)
      echo "'kind' not found in PATH. Install it: https://kind.sigs.k8s.io/docs/user/quick-start/#installation" >&2
      exit 1
      ;;
  esac
}

# macOS has no native container runtime: docker there needs a Linux VM
# behind it. Installs colima (+ docker CLI and buildx, which
# common/build-console.sh needs for `docker build --load`) via brew.
install_docker_colima() {
  brew install docker docker-buildx colima
  mkdir -p ~/.docker/cli-plugins
  ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
}

# macOS + CONTAINER_ENGINE=docker only: installs docker/colima if docker is
# missing, and starts colima if no daemon is reachable. A no-op when Docker
# Desktop (or an already-running colima) provides the daemon. The VM must
# fit the minikube node, so size it with COLIMA_CPUS / COLIMA_MEMORY (GB);
# defaults match the podman machine sizing above (host - 1 CPU, host - 4GB).
# Call after CONTAINER_ENGINE has been determined.
ensure_docker_engine() {
  if [ "${OS_NAME}" != "Darwin" ] || [ "${CONTAINER_ENGINE}" != "docker" ]; then
    return 0
  fi

  ensure_installed docker install_docker_colima

  if ! docker info >/dev/null 2>&1 && command -v colima >/dev/null 2>&1; then
    local cpus="${COLIMA_CPUS:-$(detect_default_cpus)}"
    local mem="${COLIMA_MEMORY:-$(( $(detect_default_memory_mb) / 1024 ))}"
    local vm_type="${COLIMA_VM_TYPE:-}"
    echo "No docker daemon reachable — starting colima with ${cpus} CPUs / ${mem}GB memory (vm-type: ${vm_type:-default})..."
    # COLIMA_VM_TYPE (qemu|vz) is optional; unquoted expansion on purpose so it vanishes when unset
    if ! colima start --cpu "${cpus}" --memory "${mem}" ${vm_type:+--vm-type ${vm_type}}; then
      # vz needs working nested virtualization (not available on every CI runner);
      # retry once from a clean state with the slower but more portable qemu.
      if [ "${vm_type}" != "qemu" ]; then
        echo "colima start failed with vm-type '${vm_type:-default}' — retrying with qemu..." >&2
        colima delete --force || true
        colima start --cpu "${cpus}" --memory "${mem}" --vm-type qemu
      else
        return 1
      fi
    fi
    colima list
  fi

  link_docker_socket

  if ! docker info >/dev/null 2>&1; then
    echo "docker daemon is still not reachable after start-up" >&2
    return 1
  fi
}

# skopeo's docker-daemon: transport ignores docker contexts and DOCKER_HOST and
# only talks to /var/run/docker.sock. On macOS, colima (and Docker Desktop) put
# the socket elsewhere and rely on the active context, so point
# /var/run/docker.sock at it (skopeo in build-console.sh and load-images.sh).
link_docker_socket() {
  if [ "${OS_NAME}" != "Darwin" ] || [ -S /var/run/docker.sock ] || ! command -v docker >/dev/null 2>&1; then
    return 0
  fi
  local host sock
  host="$(docker context inspect --format '{{.Endpoints.docker.Host}}' 2>/dev/null || true)"
  sock="${host#unix://}"
  if [ "${sock}" = "${host}" ] || [ ! -S "${sock}" ]; then
    # Context lookup failed or points nowhere: fall back to colima's default socket
    sock="${HOME}/.colima/default/docker.sock"
  fi
  if [ -S "${sock}" ]; then
    echo "Linking /var/run/docker.sock -> ${sock} (for skopeo's docker-daemon: transport)"
    sudo ln -sf "${sock}" /var/run/docker.sock
  else
    echo "WARNING: no docker socket found to link to /var/run/docker.sock; skopeo's docker-daemon: transport will fail" >&2
  fi
}

# envsubst (gettext) — used by deploy-example-console.sh. Linux runners ship
# it; macOS runners may not.
install_envsubst() {
  brew install gettext
  brew link --force gettext
}

# Installs skopeo — needed by both kind/load-images.sh and
# minikube/load-images.sh to push built images into the local registry.
# On Linux, also applies the AppArmor tweak skopeo needs to actually work
# on Ubuntu 24.04+ runners (restricts unprivileged user namespaces, which
# skopeo uses) — folded in here rather than left as a separate CI step,
# since it's specifically a "make skopeo work" concern, not a general one.
install_skopeo() {
  case "${OS_NAME}" in
    Darwin)
      brew install skopeo
      ;;
    Linux)
      sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
      sudo apt-get update
      sudo apt-get install -y skopeo
      ;;
  esac
}

# Ensures a podman machine exists and is running — but only on macOS.
# Native Linux podman talks to the local system directly; there's no VM to
# create or manage, so this is a no-op there regardless of CONTAINER_ENGINE.
# Only sizes the machine (via PODMAN_MACHINE_CPUS/PODMAN_MACHINE_MEMORY) on
# first-time init — an existing machine is never resized automatically,
# since that requires stopping it (killing anything running inside,
# including the kind cluster).
ensure_podman_machine() {
  if [ "${OS_NAME}" != "Darwin" ]; then
    return 0
  fi

  local name state cpus mem

  name=$(podman machine list --format json | jq -r '.[0].Name // empty')

  if [ -z "${name}" ]; then
    echo "No podman machine found — initializing 'podman-machine-default' with ${PODMAN_MACHINE_CPUS} CPUs / ${PODMAN_MACHINE_MEMORY}MB memory..."
    podman machine init --rootful --cpus "${PODMAN_MACHINE_CPUS}" --memory "${PODMAN_MACHINE_MEMORY}"
    podman machine start
    return
  fi

  state=$(podman machine inspect "${name}" | jq -r '.[0].State')
  if [ "${state}" != "running" ]; then
    echo "Starting existing podman machine '${name}'..."
    podman machine start "${name}"
  fi

  cpus=$(podman machine inspect "${name}" | jq -r '.[0].Resources.CPUs')
  mem=$(podman machine inspect "${name}" | jq -r '.[0].Resources.Memory')
  if [ "${cpus}" != "${PODMAN_MACHINE_CPUS}" ] || [ "${mem}" != "${PODMAN_MACHINE_MEMORY}" ]; then
    echo "Note: podman machine '${name}' is already sized at ${cpus} CPUs / ${mem}MB memory (requested ${PODMAN_MACHINE_CPUS}/${PODMAN_MACHINE_MEMORY}MB). Not resizing an existing machine automatically." >&2
    echo "  To resize: podman machine stop ${name} && podman machine set --cpus ${PODMAN_MACHINE_CPUS} --memory ${PODMAN_MACHINE_MEMORY} ${name} && podman machine start ${name}" >&2
  fi
}

# On native Linux with rootless podman, kube-proxy/ingress-nginx need the
# host's ip_tables kernel module loaded — rootless containers can't load
# kernel modules themselves (no CAP_SYS_MODULE), so a missing module
# surfaces confusingly later as ingress-nginx/kube-proxy failing, not as an
# obvious "module missing" error. Check up front and fail fast instead.
# No-op on macOS (podman machine VM, handled by ensure_podman_machine) and
# on rootful podman/docker (which don't hit this).
check_linux_rootless_podman_ip_tables() {
  if [ "${OS_NAME}" != "Linux" ] || [ "${CONTAINER_ENGINE}" != "podman" ]; then
    return 0
  fi

  if [ "$(podman info --format json | jq -r .host.security.rootless)" != "true" ]; then
    return 0
  fi

  if [ -z "$(lsmod | grep ^ip_tables)" ]; then
    echo "podman is running rootless on Linux, but the 'ip_tables' kernel module isn't loaded." >&2
    echo "Rootless containers can't load kernel modules themselves (no CAP_SYS_MODULE), and" >&2
    echo "kube-proxy/ingress-nginx need it on the host - without it, ingress setup fails." >&2
    echo "" >&2
    echo "Fix:" >&2
    echo "  sudo modprobe ip_tables" >&2
    echo "  echo ip_tables | sudo tee /etc/modules-load.d/ip_tables.conf   # persist across reboots" >&2
    exit 1
  fi
}
