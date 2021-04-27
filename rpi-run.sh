#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --version, -v     The rpi operating system version. (Default: stretch)
    --device, -d      The rpi device. (Default: raspi3)
    --output, -o      The output folder to write the image to (default: $output)
    --clean, -c       Clean the output folder
    --help            Shows this help.
'
    exit 1
}

# must be run as sudo
if [ $EUID -ne 0 ]; then
    echo "$0 is not run as root. Try using sudo."
    exit 2
fi

prepargs=
clean=
cwd=$(pwd)
output=`realpath rpi`
scripts=$(readlink -f $0 | xargs dirname)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|-v)             prepargs="$prepargs -v $2"; shift ;;
        --device|-d)              prepargs="$prepargs -d $2"; shift ;;
        --output|-o)              output=`realpath $2`; shift ;;
        --clean|-c)               clean="-c" ;;
        *)                        usage ;;
    esac
    shift
done

# -------------------------------------------------------------------------------

mkdir -p $output
if [ ! -f "${output}/filesystem.img" ] || \
   [ ! -f "${output}/.env" ] ; then
    rm -f "${output}/filesystem.*"
    # Prepare images
    if ! ${scripts}/rpi-prepimg.sh -o $output $prepargs ; then
        echo "Failed to prepare rpi image."
        exit
    fi
fi

# get configuration
source "${output}/.env"

# Build qemu if needed
if [ ! -f "${output}/qemu-system-${arch}" ] || \
   [ ! -f "${output}/qemu-img" ] ; then
   
    if ! ${scripts}/build-qemu.sh -o $output; then 
        echo "Failed to build qumu."
        exit
    fi
fi

# run emulator
if ! ${scripts}/rpi-emulator.sh -i $output $clean --tap ; then
    echo "Failed to start emulator in $output."
    exit
fi
