#include <string.h>
#include <errno.h>
#include <stdio.h>
#include "nuc_error.h"
char *err_str(int e)
{
	switch (e) {
	case NUC_E_MISSING_FLAGS:
		return "missing the necessary flags to start the programm";
	case NUC_INVALID_ROOTFS_PATH:
		return "invalid root filesystem path";
	case NUC_FORMAT_ERR:
		return "format string failed";
	case NUC_CGROUP_CTRL_ERR:
		return "necessary cgroup controllers not enabled";
	case NUC_HOST_NAME_ERR:
		return "hostname exceeds the max limit";
	case NUC_VETH_PAIR_ERR:
		return "could not create veth pair";
	case NUC_SET_NS_ERR:
		return "could not set namespace for veth pair";
	case NUC_SET_VETH_IP_ERR:
		return "could not set ip addr to veth pair";
	case NUC_SET_VETH_IP_UP_ERR:
		return "could not turn up veth pair ip";
	case NUC_SET_DEF_GATEWAY_ERR:
		return "failed to set default gateway";
	case NUC_SET_IP_FRWRD_ERR:
		return "could not set ip forward";
	case NUC_SET_NAT_RULE_ERR:
		return "could not set nat rule";
	default:
		return strerror(e);
	}
}

void nuc_err_report(char *step, int e)
{
	fprintf(stderr, "%s: %s\n", step, err_str(e));
}