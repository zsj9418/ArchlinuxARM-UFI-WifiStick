#!/bin/bash
set -e
. /etc/profile

USB_ATTRIBUTE=0x409
USB_GROUP=alarm
USB_SKELETON=b.1

CONFIGFS_DIR=/sys/kernel/config
USB_CONFIGFS_DIR=${CONFIGFS_DIR}/usb_gadget/${USB_GROUP}
USB_STRINGS_DIR=${USB_CONFIGFS_DIR}/strings/${USB_ATTRIBUTE}
USB_FUNCTIONS_DIR=${USB_CONFIGFS_DIR}/functions
USB_CONFIGS_DIR=${USB_CONFIGFS_DIR}/configs/${USB_SKELETON}
USB_FUNCTIONS_CNT=1

function configfs_init() {
	mkdir -p /dev/usb-ffs
	mount -t configfs none ${CONFIGFS_DIR}

	mkdir -p ${USB_CONFIGFS_DIR} -m 0770
	echo 0x2207 > ${USB_CONFIGFS_DIR}/idVendor
	echo 0x0310 > ${USB_CONFIGFS_DIR}/bcdDevice
	echo 0x0200 > ${USB_CONFIGFS_DIR}/bcdUSB

	mkdir -p ${USB_STRINGS_DIR} -m 0770
	echo "ArchLinux" > ${USB_STRINGS_DIR}/manufacturer
	echo "MSM8916" > ${USB_STRINGS_DIR}/product
	echo "0123456789ABCDEF" > ${USB_STRINGS_DIR}/serialnumber

	mkdir -p ${USB_CONFIGS_DIR} -m 0770
	mkdir -p ${USB_CONFIGS_DIR}/strings/${USB_ATTRIBUTE} -m 0770

	mkdir -p ${USB_FUNCTIONS_DIR}/ffs.adb
	echo 0x1 > ${USB_CONFIGFS_DIR}/os_desc/b_vendor_code
	echo "MSFT100" > ${USB_CONFIGFS_DIR}/os_desc/qw_sign
	echo 500 > ${USB_CONFIGS_DIR}/MaxPower
	ln -s ${USB_CONFIGS_DIR} ${USB_CONFIGFS_DIR}/os_desc/b.1
}

syslink_function() {
	ln -s ${USB_FUNCTIONS_DIR}/$1 ${USB_CONFIGS_DIR}/f${USB_FUNCTIONS_CNT}
	let USB_FUNCTIONS_CNT=USB_FUNCTIONS_CNT+1
}

modprobe gadgetfs
modprobe libcomposite

# initialize usb configfs
test -d ${USB_CONFIGFS_DIR} || configfs_init
echo "0x0018" > ${USB_CONFIGFS_DIR}/idProduct

# adbd function
syslink_function ffs.adb
mkdir /dev/usb-ffs/adb -m 0770
mount -o uid=1000,gid=1000 -t functionfs adb /dev/usb-ffs/adb
sdbd -df /var/log/sdbd.log

# start usb gadget
sleep 1
UDC=$(ls /sys/class/udc/ | awk '{print $1}')
echo $UDC > ${USB_CONFIGFS_DIR}/UDC
