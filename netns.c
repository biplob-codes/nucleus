#include <stdlib.h>
#include <stdio.h>

#define VETH_HOST_IP  "12.200.1.1/24"
#define VETH_HOST_IP2 "12.200.1.1"
#define VETH_CHILD_IP "12.200.1.2/24"
#define VETH_SUBNET   "12.200.1.0/24"
int init_netns(pid_t pid)
{
	char cmd_c_veth[256];
	snprintf(cmd_c_veth, sizeof(cmd_c_veth),
		 "ip link add n9-veth-host type veth peer name "
		 "n9-veth-%d",
		 pid);
	int r = system(cmd_c_veth);
	if (r != 0) {
		perror("create veth failed");
		return 1;
	}
	char cmd_add_interface[256];
	snprintf(cmd_add_interface, sizeof(cmd_add_interface),
		 "ip link set n9-veth-%d netns %d", pid, pid);
	r = system(cmd_add_interface);
	if (r != 0) {
		perror("add one end of veth to child failed");
		return 1;
	}
	char cmd_host_ip[256];
	snprintf(cmd_host_ip, sizeof(cmd_host_ip),
		 "ip addr add %s dev n9-veth-host", VETH_HOST_IP);
	r = system(cmd_host_ip);
	if (r != 0) {
		perror("add host ip failed");
		return 1;
	}
	char cmd_child_ip[256];
	snprintf(cmd_child_ip, sizeof(cmd_child_ip),
		 "nsenter --net=/proc/%d/ns/net ip addr add %s dev n9-veth-%d",
		 pid, VETH_CHILD_IP, pid);
	r = system(cmd_child_ip);
	if (r != 0) {
		perror("add child ip failed");
		return 1;
	}
	char cmd_host_act[] = "ip link set n9-veth-host up";
	r = system(cmd_host_act);
	if (r != 0) {
		perror("host up fail");
		return 1;
	}
	char cmd_child_act[256];
	snprintf(cmd_child_act, sizeof(cmd_child_act),
		 "nsenter --net=/proc/%d/ns/net ip link set n9-veth-%d up && "
		 "nsenter --net=/proc/%d/ns/net ip link set lo up",
		 pid, pid, pid);

	r = system(cmd_child_act);
	if (r != 0) {
		perror("child up failed");
		return 1;
	}
	char cmd_ch_def_gate[256];
	snprintf(cmd_ch_def_gate, sizeof(cmd_ch_def_gate),
		 "nsenter --net=/proc/%d/ns/net ip route add default via %s",
		 pid, VETH_HOST_IP2);
	r = system(cmd_ch_def_gate);
	if (r != 0) {
		perror("default gateway failed");
		return 1;
	}
	char cmd_port_forward[] = "sysctl -w net.ipv4.ip_forward=1";
	r = system(cmd_port_forward);
	if (r != 0) {
		perror("port forward fail");
		return 1;
	}
	char cmd_nat_forward[] = "iptables -t nat -A POSTROUTING -s "
				 "12.200.1.0/24 -o enp2s0 -j MASQUERADE";
	r = system(cmd_nat_forward);
	if (r != 0) {
		perror("port forward fail");
		return 1;
	}
	return 0;
}