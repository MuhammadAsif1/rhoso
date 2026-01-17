# RHOSO Live Migration Network Change

## Overview
This repository documents how to move OpenStack live migration traffic
from `ctlplane` to `internalapi` network in RHOSO.

## Problem Statement
Default RHOSO design uses **ctlplane (1G)** for live migration,
causing slow migrations.

## Solution
Switch live migration traffic to **internalapi (10G)** network
using updated libvirt TLS certificates.

## Architecture
- OpenShift
- RHOSO (OpenStack)
- Libvirt + TLS

## Steps

### 1- Update variables
- Update following variables in script
```
domain="ctlplane.iv.lab"
lm_network_name="internalapi"
ctlplane_network_name="ctlplane"
rootca_libvirt="rootca-libvirt"
```
- `domain` represents the `fqdn_internal_api` from nodeset file
- `lm_network_name` is the one which you want to use for Live Migration, you can fetch the network from nodeset file. Let's say in my case im using `internalapi`
- `ctlplane_network_name` give control plane network name from nodeset, in my case its value is `ctlplane`
```
    hci01: 
      hostName: hci01
      networks: 
        - name: ctlplane
          subnetName: subnet1
          defaultRoute: true
          fixedIP: 192.168.12.122
        - name: internalapi
          subnetName: subnet1
          fixedIP: 192.168.13.100
```	  
- `rootca_libvirt` Refers to libvirt rootca 

### 2- Script Execution
- Run the script 
`./lm-network-change-script.sh`

- Look at the output of the script in last part
```
deploying lm-network-change service
openstackdataplaneservice.dataplane.openstack.org/lm-network-change created
service status
NAME                AGE
lm-network-change   21s
```
- copy the service name

### 3- Changes in nodeset file
- Add lm-netowrk-change service name at the end of alredy mentioned services
```spec:
    service:
       - lm-network-change
```
- Add following two ansible variables in nodeset. Just change the name accordingly for each node .e.g hci01-tls.crt for node hci01
```spec:
  nodes:
    hci01: 
      ansible:
        ansibleVars: 
          livemigration_tls_crt: /var/lib/openstack/configs/lm-network-change/hci01-tls.crt
          livemigration_nova_host_specific: /var/lib/openstack/configs/lm-network-change/hci01-02-nova-host-specific
```		  
### 4- Deploy Nodeset
- Deploy your osdpns file
- Deploy your osdpd file

### 5- Live Migration Network Change validation
- Chose two nodes for instance Migration, Lets say we have hci01 and hci02
- Find the interface name of both nodes where `internalapi` network IP is assigned
- TCP dump on both nodes, this command will capture the packets flowing from `br-internalapi` on mentioned host IPs
```
tcpdump -nn -i br-internalapi \
'(tcp and ((host 192.168.13.100 and host 192.168.13.101)) and greater 1000)'
```
- Migrate the instance from one node(hci01) to another node(hci02)
- You must see the packets flowing in internalapi network