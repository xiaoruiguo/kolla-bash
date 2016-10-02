#!/bin/bash

apt-get install bridge-utils -y

brctl addbr br-ex

if [[ -z $(grep br-ex /etc/network/interfaces) ]]; then
cat >> /etc/network/interfaces <<EOF
auto br-ex
iface br-ex inet static
  address 192.168.254.1
  netmask 255.255.255.0
EOF
fi
ifup br-ex

apt install python-pip -y
apt install \
    vim \
    htop \
    python-dev \
    python-netaddr \
    python-openstackclient \
    python-neutronclient \
    libffi-dev \
    libssl-dev \
    gcc \
    apt-transport-https \
    ca-certificates \
    bridge-utils -y

pip install ansible==2.1.2.0

apt-get install apt-transport-https ca-certificates
apt-key adv --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 58118E89F3A912897C070ADBF76221572C52609D
deb https://apt.dockerproject.org/repo ubuntu-xenial main
echo 'deb https://apt.dockerproject.org/repo ubuntu-xenial main' > /etc/apt/sources.list.d/docker.list
apt-get update
apt-get install docker-engine -y

apt-get purge lxc lxd -y
pip install -U pip
mkdir -p /etc/systemd/system/docker.service.d
if [[ -z $(grep shared /etc/systemd/system/docker.service.d/kolla.conf) ]]; then
tee /etc/systemd/system/docker.service.d/kolla.conf <<-EOF
[Service]
MountFlags=shared
EOF
fi

systemctl daemon-reload
systemctl enable docker
systemctl restart docker

pip install ansible

git clone https://github.com/openstack/kolla
pip install kolla/

cp -r /usr/local/share/kolla/etc_examples/kolla /etc/

if [[ $(ip l | grep team) ]]; then
NETWORK_INTERFACE="team0"
elif [[ $(ip l | grep bond) ]]; then
NETWORK_INTERFACE="bond0"
elif [[ $(ip l | grep enp0s8) ]]; then
NETWORK_INTERFACE="enp0s8"
else
echo "Can't figure out network interface, please manually edit"
exit 1
fi

NEUTRON_INTERFACE="br-ex"
GLOBALS_FILE="/etc/kolla/globals.yml"
ADDRESS="$(ip -4 addr show ${NETWORK_INTERFACE} | grep "inet" | head -1 |awk '{print $2}' | cut -d/ -f1)"
BASE="$(echo ${ADDRESS} | cut -d. -f 1,2,3)"
#VIP=$(echo "${BASE}.254")
VIP="${ADDRESS}"

sed -i "s/^kolla_internal_vip_address:.*/kolla_internal_vip_address: \"${VIP}\"/g" ${GLOBALS_FILE}
sed -i "s/^network_interface:.*/network_interface: \"${NETWORK_INTERFACE}\"/g" ${GLOBALS_FILE}
sed -i "s/^#network_interface:.*/network_interface: \"${NETWORK_INTERFACE}\"/g" ${GLOBALS_FILE}

if [[ -z $(grep neutron_bridge_name ${GLOBALS_FILE}) ]]; then
cat >> ${GLOBALS_FILE} <<EOF
neutron_bridge_name: "br-ex"
enable_haproxy: "no"
enable_keepalived: "no"
kolla_base_distro: "ubuntu"
kolla_install_type: "source"
openstack_release: "3.0.0"
EOF
fi

sed -i "s/^#neutron_external_interface:.*/neutron_external_interface: \"${NEUTRON_INTERFACE}\"/g" ${GLOBALS_FILE}
sed -i "s/^127.0.1.1\(.*\)/${ADDRESS}\1/" /etc/hosts
if [[ -z $(grep ${ADDRESS} /etc/hosts) ]]; then
echo "${ADDRESS} $(hostname)" >> /etc/hosts
fi

if [ `egrep -c 'vmx|svm|0xc0f' /proc/cpuinfo` == '0' ] ;then
if [ ! -f /etc/kolla/config/nova/nova-compute.conf ]; then
mkdir -p /etc/kolla/config/nova/
tee > /etc/kolla/config/nova/nova-compute.conf <<-EOF
[libvirt]
virt_type=qemu
EOF
fi
fi

kolla-build --base ubuntu --type source --tag 3.0.0

kolla-genpwd
sed -i "s/^keystone_admin_password:.*/keystone_admin_password: admin1/" /etc/kolla/passwords.yml
kolla-ansible prechecks
if [ ! $? == 0 ]; then
  echo prechecks failed
  exit 1
fi

kolla-ansible deploy
if [ ! $? == 0 ]; then
  echo prechecks failed
  exit 1
fi

tee > /root/open.rc <<EOF
#!/bin/bash

# set environment variables for Starmer's OpenStack demo install

# "source this file, don't subshell" predicate inspired by
# http://stackoverflow.com/a/23009039/6195005

if [[ $_ == $0 ]] ; then
    echo "You ran this script instead of sourcing it."
    echo "  usage: source $0"
    echo "Aborting."
    exit 1
else
    echo "Setting environment variables in the current shell"
fi

export OS_PROJECT_DOMAIN_ID=default
export OS_USER_DOMAIN_ID=default
export OS_PROJECT_NAME=admin
export OS_TENANT_NAME=admin
export OS_USERNAME=admin
export OS_PASSWORD=$(cat /etc/kolla/passwords.yml | grep "keystone_admin_password" | awk '{print $2}')
export OS_AUTH_URL=http://${ADDRESS}:35357/v3
export OS_IDENTITY_API_VERSION=3
EOF

bash ./import_image.sh

bash ./setup_network.sh

echo "Login using http://${ADDRESS} with default as domain,  admin as username, and $(cat /etc/kolla/passwords.yml | grep "keystone_admin_password" | awk '{print $2}') as password"
