#!/usr/bin/env bash
#
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright(c) 2023 John Sanpe <sanpeqf@gmail.com>
#

lk2ndimg="build/aboot.img"
kerndtb="build/kernel-dtb"
bootimg="build/boot.img"
modules="build/modules"

livecd="build/livecd"
rootfs="$livecd/mnt"
rootimg="build/rootfs.img"

function make_boot()
{
    kernel="linux/arch/arm64/boot/Image.gz"
    dtbfile="linux/arch/arm64/boot/dts/qcom/msm8916-thwc-ufi001c.dtb"
    cat ${kernel} ${dtbfile} > ${kerndtb}
}

function make_image()
{
    unset options
    options+=" --base 0x80000000"
    options+=" --pagesize 2048"
    options+=" --second_offset 0x00f00000"
    options+=" --tags_offset 0x01e00000"
    options+=" --kernel_offset 0x00080000"
    options+=" --kernel ${kerndtb}"
    options+=" -o ${bootimg}"

    cmdline="earlycon console=ttyMSM0,115200 rootwait root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e rw"
    mkbootimg --cmdline "${cmdline}" ${options}
}

function build_lk2nd()
{
    cd lk2nd
    make TOOLCHAIN_PREFIX=arm-none-eabi- lk1st-msm8916 -j$[$(nproc) * 2]
    cp -p build-lk1st-msm8916/emmc_appsboot.mbn ../$lk2ndimg
    cd -
}

function build_linux()
{
    for file in patch/linux/*.patch; do
        patch -N -p 1 -d linux <$file
    done

    cd linux
    mkdir -p $modules
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- msm8916_defconfig
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$[$(nproc) * 2]
    make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=../$modules modules_install
    cd -
}

function prepare_livecd()
{
    liveurl="https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/os/ArchLinuxARM-aarch64-latest.tar.gz"
    livepack="build/ArchLinuxARM-aarch64-latest.tar.gz"

    if [ ! -e $livepack ]; then
        curl -L -o $livepack $liveurl
    fi

    mkdir -p $livecd
    mount --bind $livecd $livecd
    bsdtar -xpf $livepack -C $livecd
}

function prepare_rootfs()
{
    dd if=/dev/zero of=$rootimg bs=1MiB count=2048
    mkfs.ext4 $rootimg
    mount $rootimg $rootfs
}

function install_aur_package()
{
    local name=$1
    local url="https://aur.archlinux.org/$name.git"
    $chlivedo "cd /home/alarm && su alarm -c \"git clone $url $name\""
    $chlivedo "cd /home/alarm/$name && su alarm -c \"makepkg -s\""
    $chlivedo "cd /home/alarm/$name && pacstrap -cGMU /mnt ./*.tar.zst"
}

function install_url_package()
{
    local url=$1
    local name=$(uuidgen)
    $chlivedo "cd /root && curl -L -o $name $url"
    $chlivedo "cd /root && pacstrap -cGMU /mnt ./$name"
}

function config_rootfs()
{
    chlivedo="arch-chroot $livecd qemu-aarch64-static /bin/bash -c"
    chrootdo="arch-chroot $rootfs qemu-aarch64-static /bin/bash -c"
    mirror='https://mirrors.tuna.tsinghua.edu.cn/archlinuxarm/$arch/$repo'

    cp -p /usr/bin/qemu-aarch64-static $livecd/bin/qemu-aarch64-static
    echo "Server = $mirror" > $livecd/etc/pacman.d/mirrorlist

    # Initialize environment
    $chlivedo "pacman-key --init"
    $chlivedo "pacman-key --populate archlinuxarm"
    $chlivedo "pacman --noconfirm -Syyu"
    $chlivedo "pacman --noconfirm -S arch-install-scripts cloud-guest-utils"
    $chlivedo "pacman --noconfirm -S base-devel git"

    # Install basic rootfs
    for package in $(cat config/*.pkg.conf); do
        $chlivedo "pacstrap -cGM /mnt $package"
    done

    for package in $(cat config/*.aur.conf); do
        install_aur_package $package
    done

    for package in $(cat config/*.url.conf); do
        install_url_package $package
    done

    cp -p /usr/bin/qemu-aarch64-static $rootfs/bin/qemu-aarch64-static
    cp -p config/service/* $rootfs/usr/lib/systemd/system/
    cp -p config/rc.local $rootfs/etc/

    cp -rp "$modules/lib/modules" "$rootfs/lib"
    for version in $(ls "$rootfs/lib/modules"); do
        $chrootdo "depmod -av $version"
    done

    echo "Server = $mirror" > $rootfs/etc/pacman.d/mirrorlist
    $chrootdo "echo 'alarm' > /etc/hostname"
    $chrootdo "echo 'LANG=C'> /etc/locale.conf"
    $chrootdo "echo -n > /etc/machine-id"

    # Configure rootfs
    $chrootdo "useradd -d /home/alarm -m -U alarm"
    $chrootdo "echo -e 'root:root\nalarm:alarm' | chpasswd"
    $chrootdo "usermod -a -G wheel alarm"
    $chrootdo "systemctl enable $(cat config/services.conf)"
    $chrootdo "pacman-key --init"
    $chrootdo "pacman-key --populate archlinuxarm"

    rm -rf $livecd/bin/qemu-aarch64-static
    rm -rf $rootfs/bin/qemu-aarch64-static
}

function pack_rootfs()
{
    cp -rp firmware $rootfs/usr/lib/firmware
    umount $rootfs

    tune2fs -M / $rootimg
    e2fsck -yf -E discard $rootimg
    resize2fs -M $rootimg
    e2fsck -yf $rootimg
    zstd $rootimg -o $rootimg.zst
}

function generate_checksum()
{
    sha256sum $lk2ndimg > $lk2ndimg.sha256sum
    sha256sum $bootimg > $bootimg.sha256sum
    sha256sum $rootimg.zst > $rootimg.zst.sha256sum
}

#=========================
# build targets
#=========================

set -ev
cd $(dirname $(readlink -f $0))
mkdir -p build

function target_lk2nd()
{
    build_lk2nd
}

function target_kernel()
{
    build_linux
    make_boot
    make_image
}

function target_rootfs()
{
    prepare_livecd
    prepare_rootfs
    config_rootfs
    pack_rootfs
    generate_checksum
}

function target_all()
{
    target_lk2nd
    target_kernel
    target_rootfs
}

num=$#
option=""
while [ $# -ne 0 ]; do
	case $1 in
        all) option='target_all' ;;
        lk2nd) option='target_lk2nd' ;;
        kernel) option='target_kernel' ;;
        rootfs) option='target_rootfs' ;;
	esac
	if [ $((num)) -gt 0 ]; then
		shift
	fi
done

eval "${option:-'target_all'}"
echo "Done."
