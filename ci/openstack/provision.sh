#!/bin/bash

set -euo pipefail

source ci/openstack/vars.sh
if [ "${RUN_OPENSTACK_CI:-}" != "true" ]; then
    echo RUN_OPENSTACK_CI is set to false, skipping the openstack end to end test.
    exit
fi

if [ "${CI_OVER_CAPACITY:-}" == "true" ]; then
    echo the CI is over capacity, skipping the end-end test.
    exit 1
fi

echo "Keypair name: $KEYPAIR_NAME"

openstack keypair create "$KEYPAIR_NAME" > ~/.ssh/id_rsa
chmod 600 ~/.ssh/id_rsa

echo CONFIGURE THE INVENTORY

export INVENTORY="$PWD/playbooks/provisioning/openstack/sample-inventory"

mv "$INVENTORY"/ansible.cfg .

PUBLIC_IP="$(curl --silent https://api.ipify.org)"


cat << EOF >> extra-vars.yaml
openstack_ssh_public_key: $KEYPAIR_NAME
openstack_external_network_name: "38.145.32.0/22"
openstack_default_image_name: "CentOS-7-x86_64-GenericCloud-1703"
openstack_num_nodes: 1
env_id: $ENV_ID
node_ingress_cidr: "$PUBLIC_IP/32"
ssh_ingress_cidr: "$PUBLIC_IP/32"
manage_packages: False
ephemeral_volumes: True
EOF


# TODO(shadower): this just started to break. We will need to unset this from
# the sample inventory.
sed -i 's/openshift_release/#openshift_release/' "$INVENTORY"/group_vars/OSEv3.yml

cat << EOF >> "$INVENTORY"/group_vars/OSEv3.yml
openshift_master_identity_providers:
- name: 'htpasswd_auth'
  login: 'true'
  challenge: 'true'
  kind: 'HTPasswdPasswordIdentityProvider'
  filename: '/etc/origin/master/htpasswd'
openshift_master_htpasswd_users:
  test: '\$apr1\$vUfm7jQS\$C6Vn0GDScgOjzvk1PSHe1/'
openshift_disable_check: disk_availability,memory_availability,docker_storage
EOF


echo GENERATED INVENTORY
echo group_vars/all.yml:
cat $INVENTORY/group_vars/all.yml

echo
echo group_vars/OSEv3.yml
cat $INVENTORY/group_vars/OSEv3.yml

echo
echo CI provisioning custom vars:
cat extra-vars.yaml

echo
echo INSTALL OPENSHIFT

ansible-galaxy install -r playbooks/provisioning/openstack/galaxy-requirements.yaml -p roles
ansible-playbook --timeout 180 --user openshift --private-key ~/.ssh/id_rsa -i "$INVENTORY" playbooks/provisioning/openstack/provision.yaml -e @extra-vars.yaml

echo
echo INVENTORY hosts file:
cat $INVENTORY/hosts


echo SET UP DNS

cp /etc/resolv.conf resolv.conf.orig
DNS_IP=$(openstack server show dns-0.$ENV_ID.example.com --format value --column addresses | awk '{print $2}')
grep -v '^nameserver' resolv.conf.orig > resolv.conf.openshift
echo nameserver "$DNS_IP" >> resolv.conf.openshift
sudo cp resolv.conf.openshift /etc/resolv.conf
