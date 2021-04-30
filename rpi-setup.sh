#!/bin/bash

# -------------------------------------------------------------------------------
usage(){
    echo '
Usage: '"$0"'  
    --version             IoT Edge version to use.
    --parentdevice        Optional parent device for nested edge (1.2 only)

    --connectionstring    Connection string for the edge device 
        - or -
    --dpsscope, --dpskey, --dpsid        DPS scope, key and registration id
    --help      Shows this help.
'
    exit 1
}

if [ "$UID" != "0" ]; then
    echo -e "error: this script must be run as root!" >&2
    exit 99
fi

echo "Disable login..."
cat > /etc/nologin <<EOF
Initial system configuration in progress!
Currently no user login is allowed!
EOF
trap 'rm -f /etc/nologin' EXIT

parentdevice=
connectionstring=
dpsscope=
dpsid=
dpskey=
edgeversion=

echo "Reading environment from kernel command line..."
for variable in $(xargs -n1 -a /proc/cmdline); do
    if [[ $variable =~ ^[a-zA-Z0-9_-]+= ]] ; then
        export $variable
    fi
done

while [ "$#" -gt 0 ]; do
    case "$1" in
        --connectionstring)    connectionstring="$2"; shift ;;
        --parentdevice)        parentdevice="$2"; shift ;;
        --dpsscope)            dpsscope="$2"; shift ;;
        --dpskey)              dpskey="$2"; shift ;;
        --dpsid)               dpsid="$2"; shift ;;
        *)                     usage ;;
    esac
    shift
done

#
# Install dependencies
#
echo "Installing dependencies..."
export DEBIAN_FRONTEND=noninteractive
while ! apt-get update ; do 
    echo "Failed apt-get update - waiting..."
    sleep 2s 
done
apt-get install -y --no-install-recommends ca-certificates curl

osdistro=$(lsb_release -si | tr [:upper:] [:lower:])
if [[ "$osdistro" == "raspbian" ]]; then 
    osdistro="debian"
fi
oscodename=$(lsb_release -cs | tr [:upper:] [:lower:])
if [[ -z "$edgeversion" ]]; then 
    if [ $oscodename == "buster" ]; then
        edgeversion="1.2.0"
    else
        edgeversion="1.1.1"
    fi
fi
osversion=$(lsb_release -sr | tr [:upper:] [:lower:])
osarch=$(dpkg --print-architecture) 

# -------------------------------------------------------------------------------

#
# Install docker runtime
#
if [[ -f docker.installed ]] ; then
    echo "Docker runtime installed"
else
    echo "Installing Docker runtime on ${osdistro} (${oscodename}:${osarch})..."
    pkgsrc="deb [arch=${osarch}] https://packages.microsoft.com"
    if [ $osdistro == "debian" ] ; then
          if [ $oscodename == "buster" ]; then
            echo "$pkgsrc/debian/10/prod buster main" > ./microsoft-prod.list 
        elif [ $oscodename == "stretch" ]; then
            echo "$pkgsrc/debian/stretch/multiarch/prod stretch main" > ./microsoft-prod.list 
        elif [ $oscodename == "jessie" ]; then
            echo "$pkgsrc/debian/8/multiarch/prod jessie main" > ./microsoft-prod.list 
        else
            echo "$osdistro $oscodename is not supported."
            exit 2
        fi
    else
        echo "Unsupported os $osdistro."
        exit 2
    fi
    if ! curl -fSsL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor > microsoft.gpg ; then
        echo "Failed to download keys for $(cat /microsoft-prod.list)."
        exit 3
    fi
    echo "Installing moby..."
    mv ./microsoft-prod.list /etc/apt/sources.list.d/
    mv ./microsoft.gpg /etc/apt/trusted.gpg.d/
    if ! apt-get update -qq || \
       ! apt-get install -y --no-install-recommends moby-engine ; then
        echo "Failed to install docker runtime (moby-engine)."
        exit 4
    fi
    echo "Docker runtime installed."
    echo "" > docker.installed  
fi

# -------------------------------------------------------------------------------
if [[ -f iotedge.installed ]] ; then
    edgeversion=$(cat iotedge.installed)
    echo "IoT edge runtime $edgeversion on ${osdistro} (${oscodename}:${osarch})"
else
    echo "Installing IoT Edge runtime ${edgeversion} on ${osdistro} (${oscodename}:${osarch})..."
    releases="https://github.com/Azure/azure-iotedge/releases/download/${edgeversion}"
    edgever=$(echo "$edgeversion" | tr -s '-' '_')
    if [[ $edgeversion = 1.0* ]] || [[ $edgeversion = 1.1* ]] ; then
        # 
        # 1.0 and 1.1 (LTS)
        #
        [[ $osdistro == "debian" ]] && patch="-1"
        url1="${releases}/libiothsm-std_${edgeversion}${patch}-1_${osdistro}${osversion}_${osarch}.deb "
        url2="${releases}/iotedge_${edgeversion}-1_${osdistro}${osversion}_${osarch}.deb"
        if ! curl -fSsL $url1 -o libiothsm-std.deb || \
           ! curl -fSsL $url2 -o iotedge.deb ; then
            echo "Failed to download $url1 or $url2."
            exit
        fi
        if ! dpkg -i ./libiothsm-std.deb || \
           ! dpkg -i ./iotedge.deb ; then
            echo "Failed to install iot edge $edgeversion"
            exit
        fi
    else
        #
        # 1.2 and beyond
        #
        url1="${releases}/aziot-identity-service_${edgever}-1_${osdistro}${osversion}_${osarch}.deb"
        url2="${releases}/aziot-edge_${edgever}-1_${osdistro}${osversion}_${osarch}.deb"
        if ! curl -fSsL $url1 -o aziot-identity-service.deb || \
           ! curl -fSsL $url2 -o aziot-edge.deb ; then
            echo "Failed to download $url1 or $url2."
            exit
        fi
        if ! dpkg -i ./aziot-identity-service.deb || \
           ! dpkg -i ./aziot-edge.deb ; then
            echo "Failed to install iot edge $edgeversion"
            exit
        fi
    fi
    echo "$edgeversion" > iotedge.installed
fi

# -------------------------------------------------------------------------------

if [[ -z "$connectionstring" ]] ; then
    if [[ -z "$dpsscope" ]] || [[ -z "$dpsid" ]] || [[ -z "$dpskey" ]]; then
        sync
        echo "Missing connection string or dps configuration. Exiting until next start..."
        exit 0
    fi
fi

echo "Configuring IoT Edge runtime ${edgeversion} on ${osdistro} (${oscodename}:${osarch})..."
if [[ $edgeversion = 1.0* ]] || [[ $edgeversion = 1.1* ]] ; then
    # 
    # 1.0 and 1.1 (LTS)
    #
    if [[ -n "$connectionstring" ]] ; then
        echo "Using connection string to configure IoT Edge".
        cat <<EOF > /etc/iotedge/config.yaml
provisioning:
  source: "manual"
  device_connection_string: "$connectionstring"
EOF

    else
        echo "Using DPS to configure IoT Edge".
        cat <<EOF > /etc/iotedge/config.yaml
provisioning:
  source: "dps"
  global_endpoint: "https://global.azure-devices-provisioning.net"
  scope_id: "$dpsscope"
  attestation:
      method: "symmetric_key"
      registration_id: "$dpsid"
      symmetric_key: "$dpskey"
EOF

    fi

    cat <<EOF >> /etc/iotedge/config.yaml
agent:
  name: "edgeAgent"
  type: "docker"
  env: {}
  config:
    image: "mcr.microsoft.com/azureiotedge-agent:$edgeversion"
    auth: {}
hostname: $(cat /proc/sys/kernel/hostname)
EOF

    cat /etc/iotedge/config.yaml
    echo ""
    echo "Restarting..."
    sleep 3

    if ! systemctl daemon-reload || ! systemctl restart iotedge ; then
        echo "Failed to restart iotedge!"
        exit 7
    fi
    sleep 3
    systemctl status iotedge
else
    #
    # 1.2 and beyond
    #
    if [[ -n "$connectionstring" ]] ; then
        iotedge config mp --connection-string $connectionstring
    fi

    # add nested edge parent if defined
    if [[ -n "$parentdevice" ]] ; then
        cat <<EOF >> /etc/aziot/config.toml
parent_hostname = "$parentdevice"
EOF

    fi

    cat <<EOF >> /etc/aziot/config.toml
hostname = "$(cat /proc/sys/kernel/hostname)"
homedir = "/var/lib/aziot/edged"

[agent]
name = "edgeAgent"
type = "docker"

[agent.config]
image = "mcr.microsoft.com/azureiotedge-agent:$edgeversion"
EOF

    if [[ -n "$connectionstring" ]] ; then
        echo "Using connection string to configure IoT Edge".
#        cat <<EOF > /etc/aziot/config.toml
#[provisioning]
#source = "manual"
#connection_string = "$connectionstring"
#EOF

    else
        echo "Using DPS to configure IoT Edge".
        cat <<EOF > /etc/aziot/config.toml
[provisioning]
source = "dps"
global_endpoint = "https://global.azure-devices-provisioning.net"
id_scope = "$dpsscope"

[provisioning.attestation]
method = "symmetric_key"
registration_id = "$dpsid"
symmetric_key = { value = "$dpskey" } 
EOF

    fi

    cat /etc/aziot/config.toml
    echo ""
    echo "Restarting..."
    sleep 3
    if ! iotedge config apply ; then
        echo "Failed to apply configuration!"
        exit 7
    fi
    sleep 3
    iotedge system status
fi

echo "Iotedge $edgeversion (Re-)configured."
# -------------------------------------------------------------------------------
