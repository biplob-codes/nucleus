#include <stdlib.h>
#include <stdio.h>
#define VETH_HOST_CIDR	     "12.200.1.1/24"
#define VETH_HOST_IP	     "12.200.1.1"
#define VETH_CONTAINER_IP    "12.200.1.2/24"
#define VETH_SUBNET	     "12.200.1.0/24"
#define VETH_HOST_IFACE	     "nuc-vh"
#define VETH_CONTAINER_IFACE "nuc-vc"
int init_netns(pid_t pid)
{
	char container_veth[56];
	snprintf(container_veth, sizeof(container_veth), "%s-%d",
		 VETH_CONTAINER_IFACE, pid);

	char create_veth[256];
	snprintf(create_veth, sizeof(create_veth),
		 "ip link add %s type veth peer name %s", VETH_HOST_IFACE,
		 container_veth);
	int r = system(create_veth);
	if (r != 0) {
		perror("create veth failed");
		return 1;
	}

	char set_namespace[256];
	snprintf(set_namespace, sizeof(set_namespace),
		 "ip link set %s netns %d", container_veth, pid);
	r = system(set_namespace);
	if (r != 0) {
		perror("set namespace for veth failed");
		return 1;
	}

	char set_host_ip[256];
	snprintf(set_host_ip, sizeof(set_host_ip), "ip addr add %s dev %s",
		 VETH_HOST_IP, VETH_HOST_IFACE);
	r = system(set_host_ip);
	if (r != 0) {
		perror("set host ip failed");
		return 1;
	}

	char set_container_ip[256];
	snprintf(set_container_ip, sizeof(set_container_ip),
		 "nsenter --net=/proc/%d/ns/net ip addr add %s dev %s", pid,
		 VETH_CONTAINER_IP, container_veth);
	r = system(set_container_ip);
	if (r != 0) {
		perror("set child ip failed");
		return 1;
	}

	char active_host_interface[256];
	snprintf(active_host_interface, sizeof(active_host_interface),
		 "ip link set %s up", VETH_HOST_IFACE);
	r = system(active_host_interface);
	if (r != 0) {
		perror("activate host interface failed");
		return 1;
	}

	char active_container_interface[256];
	snprintf(active_container_interface, sizeof(active_container_interface),
		 "nsenter --net=/proc/%d/ns/net ip link set %s up && "
		 "nsenter --net=/proc/%d/ns/net ip link set lo up",
		 pid, container_veth, pid);
	r = system(active_container_interface);
	if (r != 0) {
		perror("active container interface failed");
		return 1;
	}

	char add_default_gateway[256];
	snprintf(add_default_gateway, sizeof(add_default_gateway),
		 "nsenter --net=/proc/%d/ns/net ip route add default via %s",
		 pid, VETH_HOST_IP);
	r = system(add_default_gateway);
	if (r != 0) {
		perror("default gateway failed");
		return 1;
	}

	char forward_port[] = "sysctl -w net.ipv4.ip_forward=1";
	r = system(forward_port);
	if (r != 0) {
		perror("port forward fail");
		return 1;
	}
	// TODO: create a fn that will give you the interface for the host
	// machine
	char forward_nat[256];
	snprintf(forward_nat, sizeof(forward_nat),
		 "iptables -t nat -A POSTROUTING -s %s -o enp2s0 -j MASQUERADE",
		 VETH_HOST_CIDR);
	r = system(forward_nat);
	if (r != 0) {
		perror("nat forward fail");
		return 1;
	}
	return 0;
}