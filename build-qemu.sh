#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'
    --version, -v   Qemu version to build (default: $qemuversion).
    --output, -o    Output folder (default: $output).
    --target        Targets other than arm and aarch64 to build.
    --help          Show this help.
'
    exit 1
}

# must be run as sudo
if [ $EUID -ne 0 ]; then
    echo "$0 is not run as root. Try using sudo."
    exit 99
fi

qemuversion="5.2.0"
output=`realpath qemu`
usegit=n
targets=("arm-softmmu" "aarch64-softmmu")
cwd=$(pwd)
twd=$(mktemp -d "${TMPDIR:-/tmp/}$(basename $0).XXXXXXXXXXXX")

while [ "$#" -gt 0 ]; do
    case "$1" in
        --version|-v)       qemuversion="$2"; shift ;;
        --target)           targets+="$2"; shift ;;
        --output|-o)        output=`realpath $2`; shift ;;
        *)                  usage ;;
    esac
    shift
done

# -------------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -qqy \
    git gpg pkg-config pv \
    python build-essential libglib2.0-dev libpixman-1-dev \
    libfdt-dev zlib1g-dev \
    flex bison ninja-build

# -------------------------------------------------------------------------------

mkdir -p $twd
cd $twd

pkg="qemu-${qemuversion}"
if [[ "$usegit" != "y" ]]; then
    if [ ! -f "${pkg}.tar.xz" ] ; then
        echo "Downloading tarball..."
        curl -fL "https://download.qemu.org/${pkg}.tar.xz" -o "${pkg}.tar.xz"
        curl -fSsL "https://download.qemu.org/${pkg}.tar.xz.sig" -o "${pkg}.sig"
        gpg --keyserver keyserver.ubuntu.com \
            --recv-keys CEACC9E15534EBABB82D3FA03353C9CEF108B584
        if ! gpg --verify "${pkg}.sig" "${pkg}.tar.xz" ; then 
            echo "Failed validation of $pkg"
            rm -f "${pkg}.tar.xz" > /dev/null 2>&1
            exit 1
        fi
    fi

    if [ ! -d $pkg ] ; then
        echo "Unpacking tarball..."
        pv "${pkg}.tar.xz" | tar -xJf -
    fi
    cd $pkg
else
    echo "Cloning qemu source..."
    git clone https://gitlab.com/qemu-project/qemu.git $pkg
    cd $pkg
    git checkout "v${qemuversion}"
    git submodule init
    git submodule update --recursive
fi

echo "Building qemu ${qemuversion} into ${output} folder."
cd $twd
rm -rf build
mkdir -p build
cd build

IFS=,;targetlist="${targets[*]}";unset IFS
echo "Configure with targets '$targetlist'"
$twd/$pkg/configure --target-list=$targetlist
if ! make -j$(nproc) ; then
    echo "Build failed."
    exit 2
fi

cp $twd/build/qemu-img $output
for target in ${targets[*]} ; do
    echo "Release ${twd}/build/${target}/* to $output..."
    cp ${twd}/build/${target}/* $output
done
cd $cwd
rm -rf $twd