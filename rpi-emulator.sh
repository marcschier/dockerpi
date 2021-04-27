#!/bin/bash
# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'
    --input, -i       Input folder with emulator and OS files.
    --image, -f       File system image name (default: filesystem.img)
    --clean, -c       Start with clean file system
    --kernel, -k      Kernel image name (default: kernel.img)
    --dtb, -d         Name of the dtb file (default: rpi.dtb)
    --machine, -m     Set qemu machine (mandatory, if not part of .env)
    --arch, -a        Set architecture (mandatory, if not part of .env)
    --append, -e      Kernel command line to append (default:none)
    --tap, -t         Use tap/tun networking instead of user.
    --help            Show this help.
'
    exit 1
}

machine=
append=
input=
arch=
kernel=
dtb=
image=
net="user"
tap="n"
clean="n"
scripts=$(readlink -f $0 | xargs dirname)

while [ "$#" -gt 0 ]; do
    case "$1" in
        --input|-i)        input=`realpath $2`; shift ;;
        --image|-f)        image="$2"; shift; echo "--image $image" ;;
        --clean|-c)        clean="y" ;;
        --kernel|-k)       kernel="$2"; shift; echo "--kernel $kernel" ;;
        --dtb|-d)          dtb="$2"; shift; echo "--dtb $dtb" ;;
        --machine|-m)      machine="$2"; shift; echo "--machine $machine" ;;
        --arch|-a)         arch="$2"; shift; echo "--arch $arch" ;;
        --tap|-t)          tap="y" ;;
        --append|-e)       append="$2"; shift ;;
        *)                 usage ;;
    esac
    shift
done

if [ -n "$input" ] && ! cd $input ; then
    echo "Input folder does not exist"
    exit 1
fi
cwd=$(pwd)

# -------------------------------------------------------------------------------

# set emulator environment variables from .env file
if [ -f ".env" ]; then
    source ".env"
fi

# set reasonable defaults
if [ -z "$image" ]; then
    image="filesystem.img"
fi
if [ -z "$kernel" ]; then
    kernel="kernel.img"
fi
if [ -z "$dtb" ]; then
    dtb="rpi.dtb"
fi

if [ -z "$arch" ] || [ -z "$machine" ]; then
    echo "Missing architecture and machine name"
    usage
fi
if [ ! -f $kernel ] || [ ! -f $dtb ]; then
    echo "Missing kernel image $kernel or dtb $dtb."
    usage
fi

# -------------------------------------------------------------------------------

# set up tap networking if needed
if [ "$tap" = "y" ] ; then
    if [ -x /dev/net/tun ] ; then
        echo "No tun support or tap management scripts not available."
        echo "Running inside docker?"
        exit 1
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -qqy iproute2 

    echo "Configuring bridge network."
    bridge=br0
    iface="$(ip route | grep "default via" | \
        awk '{ print $5 }' | head -1)"
    if [[ "$iface" == "" ]] ; then 
        echo "no network interface found."
        exit 1
    fi
    ipaddr=$(ip address show dev "$iface" | grep global \
        | grep -oP '\d{1,3}(.\d{1,3}){4}' | head -1)
    if [[ "$ipaddr" == "" ]] ; then 
        echo "no ipaddr found for $iface"
        exit 1
    fi

    # Create bridge
    ipaddrFW=$(sysctl net.ipv4.ip_forward | cut -d= -f2)
    sysctl net.ipv4.ip_forward=1
    echo "Getting routes for interface: $iface"
    routes=$(ip route | grep $iface)
    br_routes=$(echo "$routes" | sed "s=$iface=$bridge=")
    
    echo "Creating new bridge: $bridge"
    ip link add $bridge type bridge
    echo "Adding $iface interface to bridge $bridge"
    ip link set dev $iface master $bridge
    echo "Setting link up for: $bridge"
    ip link set dev $bridge up
    echo "Flusing routes to interface: $iface"
    ip route flush dev $iface
    echo "Adding ipaddr address to bridge: $bridge"
    ip address delete $ipaddr dev $iface
    ip address add $ipaddr dev $bridge
    echo "Adding routes to bridge: $bridge"
    echo "$br_routes" | tac | while read l; do
    ip route add $l
    done

    # create tap interface
    precreationg=$(ip tuntap list | cut -d: -f1 | sort)
    ip tuntap add user $USER mode tap
    postcreation=$(ip tuntap list | cut -d: -f1 | sort)
    tap=$(comm -13 <(echo "$precreationg") <(echo "$postcreation"))
    net="tap,ifname=$tap"
    echo "Tap interface $tap added."

    # restore on exit
restore() {
    ip link set down dev $tap 
    ip tuntap del $tap mode tap 
    sysctl net.ipv4.ip_forward="$ipaddrFW" 
    echo "Setting link down for: $bridge"
    ip link set dev $bridge down
    echo "Removing bridge: $bridge"
    ip link delete dev $bridge type bridge
    ip address add $ipaddr dev $iface
    echo "Restoring routes to interface $iface"
    echo "$routes" | tac | while read l; do
        ip route add $l 
    done
    echo "Restored networking."
}
    trap restore EXIT

    # add / remove tap to bridge as part of qemu
    cat > $cwd/qemu-ifup <<EOF
#!/bin/sh
echo "Executing /etc/qemu-ifup"
echo "Bringing up \$1 for bridged mode..."
sudo ip link set dev \$1 up promisc on
echo "Adding \$1 to $bridge..."
sudo ip link set dev \$1 master $bridge
sleep 2
sudo ip link show master $bridge
EOF

    cat > $cwd/qemu-ifdown <<EOF
#!/bin/sh
echo "Executing /etc/qemu-ifdown"
sudo ip link set dev \$1 down
echo "Adding \$1 to $bridge..."
sudo ip link set dev \$1 nomaster $bridge
sudo ip link delete dev \$1
EOF

    chmod 750 $cwd/qemu-ifdown $cwd/qemu-ifup
    net="$net,script=$cwd/qemu-ifup,downscript=$cwd/qemu-ifdown"
fi

# -------------------------------------------------------------------------------

if [ ! -f "qemu-system-${arch}" ] || [ ! -f "qemu-img" ] ; then 
    echo "Missing qemu.  Use build-qemu.sh to build first."
    exit 1
fi

if [ -f "filesystem.qcow2" ] && [ "$clean" = "y" ] ; then 
    echo "Reset existing file system."
    rm -f filesystem.qcow2
fi

if [ ! -f "filesystem.qcow2" ] ; then 
    if [ -f $image ]; then
        image_size=`du -m $image | cut -f1`
        new_size=$(( ( ( ( image_size - 1 ) / 2048 ) + 1 ) * 2 ))
        ./qemu-img convert -f raw -O qcow2 $image filesystem.qcow2
        ./qemu-img resize filesystem.qcow2 "${new_size}G"
    else
        echo "Missing file system image $image."
        exit 1
    fi
fi

# -------------------------------------------------------------------------------

append="root=/dev/mmcblk0p2 rootwait panic=1 ${append}"
append="dwc_otg.lpm_enable=0 dwc_otg.fiq_fsm_enable=0 ${append}"
append="rw earlyprintk loglevel=8 console=ttyAMA0,115200 ${append}"

echo "Booting ${machine} from ${cwd}..."
./qemu-system-$arch -M $machine -m 1G -smp 4 \
    -monitor telnet:127.0.0.1:55555,server,nowait \
    -dtb $dtb -kernel $kernel -drive "file=filesystem.qcow2" \
    -append "${append}" \
    -netdev $net,id=net0 -device usb-net,netdev=net0,mac=02:ca:fe:f0:0d:01 \
    -display none -serial mon:stdio 

# -------------------------------------------------------------------------------
