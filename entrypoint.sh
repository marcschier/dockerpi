#!/bin/sh

# floppy_path=
# target=
# kernel_image
# image_path
# zip_path

if [ -z "$target" ] || [ $target != pi* ]; then
# support original behavior
target="${1:-pi1}"
fi

usage(){
    echo '
Usage: '"$0"'
    --target  Set target device (pi1, pi2, or pi3)
    --zip     Path to file system image zip file (default:${zip_path})
    --img     Path of file system image file (default:${image_path})
    --kernel  Kernel image (default: kernel-qemu-4.19.50-buster)
    --floppy  Host folder to add as floppy (fda).
    --help    Show this help.
'
    exit 1
}
if [[ $target != pi* ]]; then 
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)   target="$2" ;;
      --img)      image_path="$2" ;;
      --zip)      zip_path="$2" ;;
      --kernel)   kernel_image="$2" ;;
      --floppy)   floppy_path="$2" ;;
      --help)     usage ;;
    esac
    shift
  done
fi
# set defaults
if [ -z "$image_path" ]; then
  image_path="/sdcard/filesystem.img"
fi
if [ -z "$zip_path" ]; then
  zip_path="/filesystem.zip"
fi
if [ -z "$kernel_image" ]; then
  kernel_image="kernel-qemu-4.19.50-buster"
fi

if [ ! -e $image_path ]; then
  echo "No filesystem detected at ${image_path}!"
  if [ -e $zip_path ]; then
      echo "Extracting fresh filesystem..."
      unzip $zip_path
      mv -- *.img $image_path
  else
    exit 1
  fi
fi

if [ "${target}" = "pi1" ]; then
  emulator=qemu-system-arm
  kernel="/root/qemu-rpi-kernel/${kernel_image}"
  dtb="/root/qemu-rpi-kernel/versatile-pb.dtb"
  machine=versatilepb
  memory=256m
  root=/dev/sda2
  extra=''
  nic='--net nic --net user,hostfwd=tcp::5022-:22'
elif [ "${target}" = "pi2" ]; then
  emulator=qemu-system-arm
  machine=raspi2
  memory=1024m
  kernel_pattern=kernel7.img
  dtb_pattern=bcm2709-rpi-2-b.dtb
  extra='dwc_otg.fiq_fsm_enable=0'
  nic='-netdev user,id=net0,hostfwd=tcp::5022-:22 -device usb-net,netdev=net0'
elif [ "${target}" = "pi3" ]; then
  emulator=qemu-system-aarch64
  machine=raspi3
  memory=1024m
  kernel_pattern=kernel8.img
  dtb_pattern=bcm2710-rpi-3-b-plus.dtb
  extra='dwc_otg.fiq_fsm_enable=0'
  nic='-netdev user,id=net0,hostfwd=tcp::5022-:22 -device usb-net,netdev=net0'
else
  echo "Target ${target} not supported"
  echo "Supported targets: pi1 pi2 pi3"
  exit 2
fi

if [ -n "${floppy_path}" ] && [ -e ${floppy_path} ]; then
  echo "Add floppy ${floppy_path} to guest."
  fda="-fda fat:floppy:${floppy_path}"
else
  fda=''
fi

if [ "${kernel_pattern}" ] && [ "${dtb_pattern}" ]; then
  fat_path="/fat.img"
  echo "Extracting partitions"
  fdisk -l ${image_path} \
    | awk "/^[^ ]*1/{print \"dd if=${image_path} of=${fat_path} bs=512 skip=\"\$4\" count=\"\$6}" \
    | sh

  echo "Extracting boot filesystem"
  fat_folder="/fat"
  mkdir -p "${fat_folder}"
  fatcat -x "${fat_folder}" "${fat_path}"

  root=/dev/mmcblk0p2

  echo "Searching for kernel='${kernel_pattern}'"
  kernel=$(find "${fat_folder}" -name "${kernel_pattern}")

  echo "Searching for dtb='${dtb_pattern}'"
  dtb=$(find "${fat_folder}" -name "${dtb_pattern}")
fi

if [ "${kernel}" = "" ] || [ "${dtb}" = "" ]; then
  echo "Missing kernel='${kernel}' or dtb='${dtb}'"
  exit 2
fi

if [ "${target}" != "pi1" ]; then
  echo "Rounding image size up to a multiple of 2G"
  image_size=`du -m $image_path | cut -f1`
  new_size=$(( ( ( image_size / 2048 ) + 1 ) * 2 ))
  echo "from ${image_size}M to ${new_size}G"
  qemu-img resize -f raw $image_path "${new_size}G"
fi

echo "Booting ${target} QEMU machine \"${machine}\" with kernel=${kernel} and dtb=${dtb}"
exec ${emulator} \
  --machine "${machine}" \
  --cpu arm1176 \
  --m "${memory}" \
  --drive "format=raw,file=${image_path}" \
  ${fda} \
  ${nic} \
  --dtb "${dtb}" \
  --kernel "${kernel}" \
  --append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=${root} rootwait panic=1 ${extra}" \
  --no-reboot \
  --display none \
  --serial mon:stdio
