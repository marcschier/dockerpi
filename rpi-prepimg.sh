#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'
    --version, -v     The rpi operating system version. (Default: stretch)
    --device, -d      The rpi device. (Default: raspi3)
    --output, -o      The output folder to write the image to (default: rpi)
    --clean, -c       Clean the output folder
    --dockerize       Build docker image
    --help            Shows this help
'
    exit 1
}

# must be run as sudo
if [ $EUID -ne 0 ]; then
    echo "$0 is not run as root. Try using sudo."
    exit 2
fi

osversion=
device=
clean="n"
dockerize="n"
cwd=$(pwd)
output=`realpath rpi`
twd=$(mktemp -d "${TMPDIR:-/tmp/}$(basename $0).XXXXXXXXXXXX")
scripts=$(readlink -f $0 | xargs dirname)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|-v)             osversion="$2"; shift ;;
        --device|-d)              device="$2"; shift ;;
        --output|-o)              output=`realpath $2`; shift ;;
        --clean|-c)               clean="y" ;;
        --dockerize)              dockerize="y" ;;
        *)                        usage ;;
    esac
    shift
done

if [[ -z "$osversion" ]] ; then
    osversion="stretch"
fi

location="http://downloads.raspberrypi.org/raspbian_lite/images"
case "$osversion" in
    8|jessie)
osversion=jessie
name=raspbian-jessie-lite
url=${location}/raspbian_lite-2017-07-05/2017-07-05-${name}.zip
imgsha2="f143cb29140209a7a9fccc5395c9e2d924a0ca82976a4ec9b31b7d1478856531" 
[ -z "$device" ] && device="raspi2b" 
;;
    9|stretch)
osversion=stretch
name=raspbian-stretch-lite
url=${location}/raspbian_lite-2019-04-09/2019-04-08-${name}.zip
imgsha2="03ec326d45c6eb6cef848cf9a1d6c7315a9410b49a276a6b28e67a40b11fdfcf" 
[ -z "$device" ] && device="raspi3b-arm"
;;
    10|buster)
osversion=buster
name=raspbian-buster-lite
url=${location}/raspbian_lite-2020-02-14/2020-02-13-${name}.zip
imgsha2="12ae6e17bf95b6ba83beca61e7394e7411b45eba7e6a520f434b0748ea7370e8"
[ -z "$device" ] && device="raspi3b"
;;
    *)
echo "Unsupported os version $osversion"
usage
;;
esac

#
# kernel.img is 32-bit for BCM2835 (RPi1 & Zero)
# kernel7.img is 32-bit for BCM2836 (RPi2) and BCM2837 (RPi3)
# kernel7l.img is 32-bit for BCM2711 (RPi4)
# kernel8.img is 64-bit for BCM2837 (RPi3) or BCM2711 (RPi4)
#
case "$device" in 
    pi0|raspi0)
arch="arm"
machine="raspi0"
kernel="kernel"
dtb="bcm2709-rpi-zero" 
;;
    pi1|raspi1ap)
arch="arm"
machine="raspi1ap"
kernel="kernel"
dtb="bcm2709-rpi-1-a-plus" 
;;
    pi2|raspi2b)
arch="arm"
machine="raspi2b"
kernel="kernel7"
dtb="bcm2709-rpi-2-b"
;;
    pi3|raspi3b)
arch="aarch64"
machine="raspi3b"
kernel="kernel8"
dtb="bcm2710-rpi-3-b-plus"
;;
    pi3a|raspi3ap)
arch="aarch64" 
machine="raspi3ap"
kernel="kernel8"
dtb="bcm2710-rpi-3-b-plus"
;;
    raspi3b-arm)
arch="arm"
machine="raspi3b"
kernel="kernel7"
dtb="bcm2710-rpi-3-b-plus"
;;
    raspi3ap-arm)
arch="arm"
machine="raspi3ap"
kernel="kernel7"
dtb="bcm2710-rpi-3-b-plus"
;;
    *)
echo "Device type ${device} not supported"
usage
;;
esac

# -------------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qqy \
    curl coreutils sed fdisk tar bzip2 zip parted mount \
    fatcat kpartx bc e2fsprogs rsync wget 

# -------------------------------------------------------------------------------

# cleanup
cleanup(){
    dmsetup remove_all > /dev/null 2>&1
    losetup -D > /dev/null 2>&1
    rm -rf $twd/prep
}

cd $cwd
mkdir -p $output

# download image 
cd $output
if [[ ! -f "${name}.zip" ]] ; then
    echo "Downloading rasbian:$osversion os image $name to $output..."
    if ! curl -fSsL ${url} -o ${name}.zip || \
        ! echo "${imgsha2}  ${name}.zip" | sha256sum -c ; then
        echo "ERROR: Failed to download $name image from $url."
        exit
    fi
else
    echo "Using existing image $name ..."
fi

# create file system image
cleanup
mkdir -p $twd/prep
cd $twd/prep
# modify for qemu and first run using https://github.com/bablokb/apiinst
script=https://raw.githubusercontent.com/bablokb/apiinst/master/bin/apiinst
echo "Patching os image $name for first boot..."
if ! curl -fSsL $script -o apiinst ; then
    echo "ERROR: Failed to download $script."
    exit
fi
chmod +x apiinst
mkdir -p config-files-dir/usr/local/sbin
mkdir -p config-files-dir/etc/ssh
sed -i 's/modprobe/msg/' apiinst
cat <<EOF > cp3.sh
#!/bin/bash
find "\$1" -name "${kernel}.img" -exec cp {} $output/kernel.img \;
find "\$1" -name "${dtb}.dtb" -exec cp {} $output/rpi.dtb \;
EOF

chmod +x cp3.sh
cat $scripts/rpi-setup.sh > config-files-dir/usr/local/sbin/apiinst2
chmod +x config-files-dir/usr/local/sbin/apiinst2
if  ! dd if=/dev/zero of=fs.img bs=16M count=240 conv=sparse || \
    ! ./apiinst -i $output/${name}.zip -t fs.img \
        -Q -3 ./cp3.sh config-files-dir/ ; then
    echo "ERROR: Failed to create image and run apiinst script!"
    exit
fi
du --block-size=1G fs.img
mv fs.img $output/filesystem.img
cleanup

if [ ! -f "$output/kernel.img" ] || \
   [ ! -f "$output/rpi.dtb" ] || \
   [ ! -f "$output/filesystem.img" ] ; then 
    echo "ERROR: Kernel or dtb missing for $osversion os!"
    exit 1
fi
cat <<EOF > $output/.env
arch=$arch
machine=$machine
EOF

# create rpi docker image
if [ "$dockerize" = "y" ]; then
    mkdir -p $twd/docker
    cd $twd/docker
    tar -cvzf sdcard.tar.gz \
        $output/filesystem.img $output/kernel.img \
        $output/rpi.dtb $output/.env

    # start our engine
    docker buildx create --name mybuilder --use  > /dev/null 2>&1
    echo "Building rpi:$osversion docker image..."
    cp $scripts/Dockerfile .
    cp $scripts/rpi-emulator.sh .
    if ! docker buildx build --load --progress plain \
        --platform linux/amd64 \
        --target rpi --tag rpi:$osversion . ; then 
        echo "ERROR: Error building rpi:$osversion!"
        exit
    fi
fi
cd $cwd
rm -rf $twd
echo "Completed building image $name."

# -------------------------------------------------------------------------------
