#include <stdlib.h>
#include <sys/stat.h>
#include <stdio.h>
#include <errno.h>
#include "nuc_error.h"
#include "config.h"
int setup_config(Config *conf, char **hostname, char **fs)
{
	if (*hostname == NULL) {
		*hostname = "nucleus";
	}
	conf->hostname = *hostname;
	struct stat st;
	if (stat(*fs, &st) != 0 || S_ISDIR(st.st_mode) == 0) {
		errno = NUC_INVALID_ROOTFS_PATH;
		return -1;
	}
	conf->root_fs = *fs;
	return 0;
}