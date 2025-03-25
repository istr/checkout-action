#!/usr/bin/env sh
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -Ceu
IFS=$(printf '\n\t')

g() {
  IFS=' '
  __g_cmd="$*"
  IFS=$(printf '\n\t')
  printf '::group::%s\n' "${__g_cmd#retry }"
  "$@"
  printf '::endgroup::\n'
}
retry() {
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if "$@"; then
      return 0
    else
      sleep "${i}"
    fi
  done
  "$@"
}
bail() {
  printf '::error::%s\n' "$*"
  exit 1
}
warn() {
  printf '::warning::%s\n' "$*"
}
_sudo() {
  if command -v sudo >/dev/null; then
    sudo "$@"
  else
    "$@"
  fi
}
apt_update() {
  retry _sudo apt-get -o Acquire::Retries=10 -qq update
  apt_updated=1
}
apt_install() {
  if test -z "${apt_updated:-}"; then
    apt_update
  fi
  retry _sudo apt-get -o Acquire::Retries=10 -o Dpkg::Use-Pty=0 install -y --no-install-recommends "$@"
}
dnf_install() {
  retry _sudo "${dnf}" install -y "$@"
}
zypper_install() {
  retry _sudo zypper install -y "$@"
}
pacman_install() {
  retry _sudo pacman -Sy --noconfirm "$@"
}
# NB: sync with action.yml
apk_install() {
  if command -v sudo >/dev/null; then
    retry sudo apk --no-cache add "$@"
  elif command -v doas >/dev/null; then
    retry doas apk --no-cache add "$@"
  else
    retry apk --no-cache add "$@"
  fi
}
# NB: sync with action.yml
opkg_update() {
  _sudo mkdir -p -- /var/lock
  retry _sudo opkg update
  opkg_updated=1
}
opkg_install() {
  if test -z "${opkg_updated:-}"; then
    opkg_update
  fi
  retry _sudo opkg install "$@"
}
sys_install() {
  case "${base_distro}" in
    debian) apt_install "$@" ;;
    fedora) dnf_install "$@" ;;
    suse) zypper_install "$@" ;;
    arch) pacman_install "$@" ;;
    alpine) apk_install "$@" ;;
    openwrt) opkg_install "$@" ;;
  esac
}

wd=$(pwd)

base_distro=''
case "$(uname -s)" in
  Linux)
    host_os=linux
    if test -e /etc/redhat-release; then
      # /etc/os-release is available on RHEL/CentOS 7+
      base_distro=fedora
    elif test -e /etc/debian_version; then
      # /etc/os-release is available on Debian 7+
      base_distro=debian
    elif test -e /etc/os-release; then
      while IFS='=' read -r key value; do
        if test "${key}" = "ID"; then
          base_distro="${value}"
        elif test "${key}" = "ID_LIKE"; then
          base_distro="${value}"
          break
        fi
      done </etc/os-release
      base_distro="${base_distro#\"}"
      base_distro="${base_distro%\"}"
    fi
    case "${base_distro}" in
      fedora)
        dnf=dnf
        if ! command -v dnf >/dev/null; then
          if command -v microdnf >/dev/null; then
            # fedora-based distributions have "minimal" images that
            # use microdnf instead of dnf.
            dnf=microdnf
          else
            # If neither dnf nor microdnf is available, it is
            # probably an RHEL7-based distribution that does not
            # have dnf installed by default.
            dnf=yum
          fi
        fi
        ;;
    esac
    ;;
  Darwin) host_os=macos ;;
  MINGW* | MSYS* | CYGWIN* | Windows_NT) host_os=windows ;;
  *) bail "unrecognized OS type '$(uname -s)'" ;;
esac

if ! command -v git >/dev/null; then
  case "${host_os}" in
    linux*)
      case "${base_distro}" in
        debian | fedora* | suse* | arch | alpine | openwrt)
          printf '::group::Install packages required for checkout (git)\n'
          case "${base_distro}" in
            debian) sys_install ca-certificates git ;;
            openwrt) sys_install git git-http ;;
            *) sys_install git ;;
          esac
          printf '::endgroup::\n'
          ;;
        *) warn "checkout-action requires git on non-Debian/Fedora/SUSE/Arch/Alpine/OpenWrt-based Linux" ;;
      esac
      ;;
    macos) warn "checkout-action requires git on macOS" ;;
    windows) warn "checkout-action requires git on Windows" ;;
    *) bail "unsupported host OS '${host_os}'" ;;
  esac
fi

g git version

case "${host_os}" in
  # error: could not lock config file C:/tools/cygwin/home/runneradmin/.gitconfig: No such file or directory
  windows) g git config --global --add safe.directory "${wd}" || true ;;
  *) g git config --global --add safe.directory "${wd}" ;;
esac

g git init

g git remote add origin "${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}"

g git config --local gc.auto 0

if test "${GITHUB_REF}" = "refs/heads/"*; then
  branch="${GITHUB_REF#refs/heads/}"
  remote_ref="refs/remotes/origin/${branch}"
  g retry git fetch --no-tags --prune --no-recurse-submodules --depth=1 origin "+${GITHUB_SHA}:${remote_ref}"
  g retry git checkout --force -B "${branch}" "${remote_ref}"
else
  g retry git fetch --no-tags --prune --no-recurse-submodules --depth=1 origin "+${GITHUB_SHA}:${GITHUB_REF}"
  g retry git checkout --force "${GITHUB_REF}"
fi

case "${host_os}" in
  # error: could not lock config file C:/tools/cygwin/home/runneradmin/.gitconfig: No such file or directory
  windows) g git config --global --add safe.directory "${wd}" || true ;;
  *) g git config --global --add safe.directory "${wd}" ;;
esac
