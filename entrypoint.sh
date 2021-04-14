#!/bin/sh

# append=
# target=
# kernel_image
# image_path
# archive_path
# image_size

if [ -z "$target" ] || [ $target != pi* ]; then
# support original behavior
target="${1:-pi1}"
fi
usage(){
    echo '
Usage: '"$0"'
    --target  Set target device (pi1, pi2, or pi3)
    --archive Path to file system archive file (default:${archive_path})
    --img     Path of file system image file (default:${image_path})
    --size    Image size in GB (default: rounded up to next 2 GB)
    --kernel  Kernel image (default: kernel-qemu-4.19.50-buster)
    --append  Kernel command line to append (default:none)
    --help    Show this help.
'
    exit 1
}
if [[ $target != pi* ]]; then 
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --target)   target="$2" ;;
      --img)      image_path="$2" ;;
      --archive)  archive_path="$2" ;;
      --kernel)   kernel_image="$2" ;;
      --size)     image_size="$2" ;;
      --append)   append="$2" ;;
      --help)     usage ;;
    esac
    shift
  done
fi

# set defaults
if [ -z "$image_path" ]; then
  image_path="/sdcard/filesystem.img"
fi
if [ -z "$archive_path" ]; then
  archive_path="/filesystem.tar.gz"
fi
if [ -z "$kernel_image" ]; then
  kernel_image="kernel-qemu-4.19.50-buster"
fi
if [ -z "$target" ]; then
  target="pi1"
fi

if [ ! -e $image_path ]; then
  echo "No filesystem detected at ${image_path}!"
  if [ -e $archive_path ]; then
      echo "Extracting fresh filesystem..."
      tar -xzf $archive_path
      mv -- *.img $image_path
  else
    echo "Specify filesystem archive file using --archive."
    usage
  fi
fi

#kernel.img is 32-bit for BCM2835 (RPi1 & Zero)
#kernel7.img is 32-bit for BCM2836 (RPi2) and BCM2837 (RPi3)
#kernel7l.img is 32-bit for BCM2711 (RPi4)
#kernel8.img is 64-bit for BCM2837 (RPi3) or BCM2711 (RPi4)

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

if [ -z "$image_size" ] ; then 
  image_size=`du -m $image_path | cut -f1`
  echo "Rounding image size up from ${image_size}M"
fi
new_size=$(( ( ( ( image_size - 1 ) / 2048 ) + 1 ) * 2 ))
echo "Resize image to ${new_size}G"
qemu-img resize -f raw $image_path "${new_size}G"

echo "Booting \"${machine}\" for ${target} (kernel=${kernel}, dtb=${dtb}, root=${root}, commandline=\"${append}\")"
exec ${emulator} \
  --machine "${machine}" \
  --cpu arm1176 \
  --m "${memory}" \
  --drive "format=raw,file=${image_path}" \
  ${nic} \
  --dtb "${dtb}" \
  --kernel "${kernel}" \
  --append "rw earlyprintk loglevel=8 console=ttyAMA0,115200 dwc_otg.lpm_enable=0 root=${root} rootwait panic=1 ${extra} ${append}" \
  --no-reboot \
  --display none \
  --serial mon:stdio
