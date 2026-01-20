#!/bin/bash
domain="ctlplane.iv.lab" #Domain nodes, present in node section of osdpns
lm_network_name="internalapi" #name of the network on which you want to have Live Migration. can get it from osdpns
ctlplane_network_name="ctlplane"
rootca_libvirt="rootca-libvirt"

######################osdps######################
cat <<EOF > livemigration-network-change.yml
apiVersion: dataplane.openstack.org/v1beta1
kind: OpenStackDataPlaneService
metadata:
  name: lm-network-change
  namespace: openstack
spec:
  edpmServiceType: lm-network-change

  dataSources:
EOF


echo "Getting ca.key"
oc get secret rootca-libvirt -n openstack -o jsonpath='{.data.tls\.key}' | base64 -d > ca.key
all_nodesets=$(oc get osdpns -n openstack -o name)
for nodeset in $all_nodesets;
do
	echo $nodeset
	nodes=$(oc get $nodeset -n openstack -o yaml | yq '.spec.nodes | keys | .[]')
	for n in $nodes; 
	do 
		echo "node : $n"
		oc get secret cert-libvirt-default-$n -n openstack -o jsonpath='{.data.ca\.crt}' | base64 -d > $n-ca.crt
	        oc get secret cert-libvirt-default-$n -n openstack -o jsonpath='{.data.tls\.key}' | base64 -d > $n-tls.key
		lm_network_node_ip=$(oc get $nodeset -o jsonpath="{.spec.nodes.$n.networks[?(@.name=='${lm_network_name}')].fixedIP}")
		
REGEN_CERT=false
if oc get secret cert-libvirt-default-livemigration-$n -n openstack >/dev/null 2>&1; then
	echo "cert exists"
	oc extract secret/cert-libvirt-default-livemigration-$n --to . --confirm
	openssl x509 -checkend 0 -noout -in $n-tls.crt || REGEN_CERT=true
	SAN=$(openssl x509 -in $n-tls.crt -noout -ext subjectAltName | tr -d ' ')
	echo "$SAN" | grep -q "$n.$domain" || REGEN_CERT=true
	echo "$SAN" | grep -q "$lm_network_node_ip" || REGEN_CERT=true
else
	echo "cert does not exist"
	REGEN_CERT=true
fi


if $REGEN_CERT; then
  echo "🔄 Regenerating cert"

		
cat <<EOF > openssl-san.cnf
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
distinguished_name = dn
req_extensions     = req_ext

[ dn ]
CN = $n
O  = $rootca_libvirt

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $n.$domain
IP.1  = $lm_network_node_ip
EOF
		echo "Generating $n-tls.csr"
		openssl req -new -key $n-tls.key -out $n-tls.csr -config openssl-san.cnf
		echo "Verify csr certificate for node $n"
		openssl req -in $n-tls.csr -noout -text | grep -A2 "Subject Alternative Name"
		echo "Sign CSR using CA"
		openssl x509 -req \
			-in $n-tls.csr \
			-CA $n-ca.crt \
			-CAkey ca.key \
			-CAcreateserial \
			-out $n-tls.crt \
			-days 1825 \
			-sha256 \
			-extensions req_ext \
			-extfile openssl-san.cnf
		echo "Creating secret cert-libvirt-default-livemigration-$n"
		oc -n openstack create secret generic cert-libvirt-default-livemigration-$n \
			--from-file=$n-tls.crt=$n-tls.crt \
			--from-file=$n-tls.key=$n-tls.key \
			--dry-run=client -o yaml | oc apply -f -
else
  echo "✅ Cert valid"
fi
		yq -i '.spec.dataSources |=(. // []) + [{"secretRef":{"name":"cert-libvirt-default-livemigration-'$n'"}}]' livemigration-network-change.yml

		
		ctlplane_network_node_ip=$(oc get $nodeset -n openstack -o jsonpath="{.spec.nodes.$n.networks[?(@.name=='${ctlplane_network_name}')].fixedIP}")
		cat <<EOF > 02-nova-host-specific.conf
[DEFAULT]
my_ip = $ctlplane_network_node_ip
host = $n.$domain

[libvirt]
live_migration_with_native_tls = True

#live_migration_uri = qemu+tls://%s/system
live_migration_scheme = qemu+tls
live_migration_inbound_addr = $lm_network_node_ip

EOF

		if oc get configmap $n-02-nova-host-specific -n openstack >/dev/null 2>&1; 
		then
		echo "ConfigMap $n-02-nova-host-specific exists. Deleting..."
		oc delete configmap $n-02-nova-host-specific -n openstack
		else
		 echo "ConfigMap $n-02-nova-host-specific does not exist. Nothing to do."
		fi
				
		oc create configmap -n openstack $n-02-nova-host-specific --from-file=$n-02-nova-host-specific=02-nova-host-specific.conf
		yq -i '.spec.dataSources |=(. // []) + [{"configMapRef":{"name":"'$n'-02-nova-host-specific"}}]' livemigration-network-change.yml
		echo "----------------------------------------------------------------------------------"
	done
done

cat >> livemigration-network-change.yml <<'EOF'

  playbookContents: |
    - name: Install live migration TLS certs
      hosts: all
      become: true
      gather_facts: false

      vars:
        target_certs:
          - /etc/pki/libvirt/servercert.pem
          - /etc/pki/libvirt/clientcert.pem
          - /etc/pki/qemu/server-cert.pem
          - /etc/pki/qemu/client-cert.pem
          - /var/lib/openstack/certs/libvirt/default/tls.crt
        target_nova_host_specific:
          - /var/lib/openstack/config/nova/02-nova-host-specific.conf

      tasks:
        - name: Copy tls.crt for this node
          ansible.builtin.copy:
            src: "{{ livemigration_tls_crt }}"
            dest: "{{ item }}"
            owner: root
            group: root
            mode: "0644"
          loop: "{{ target_certs }}"
        - name: Copy 02-nova-host-specific for this node
          ansible.builtin.copy:
            src: "{{ livemigration_nova_host_specific }}"
            dest: "{{ item }}"
            owner: root
            group: root
            mode: "0644"
          loop: "{{ target_nova_host_specific }}"
        - name: Scan SSH host keys on migration network
          command: "ssh-keyscan -H {{ hostvars[item].internalapi_ip }}"
          register: sshkeyscan
          changed_when: false
          loop: "{{ ansible_play_hosts }}"
        - name: Add migration IPs to known_hosts
          ansible.builtin.known_hosts:
            path: /root/.ssh/known_hosts
            name: "{{ hostvars[item.item].internalapi_ip }}"
            key: "{{ item.stdout }}"
          when: item.rc == 0
          loop: "{{ sshkeyscan.results }}"
        - name: Restart nova-compute container
          become: true
          containers.podman.podman_container:
            name: nova_compute
            state: started
            restart: true
EOF



echo "Deleting old service and applying new service"
################################
if oc get osdps lm-network-change -n openstack >/dev/null 2>&1; 
then
	echo "osdps lm-network-change exists. Deleting..."
	oc delete osdps lm-network-change -n openstack
else
	echo "osdps lm-network-change does not exist. Nothing to do."
fi
echo "deploying lm-network-change service"
oc apply -f livemigration-network-change.yml
sleep 20
echo "service status"
oc get osdps lm-network-change -n openstack
