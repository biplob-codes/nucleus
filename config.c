#include <stdlib.h>
#include <sys/stat.h>
#include <stdio.h>
#include <errno.h>
#include <string.h>
#include "nuc_error.h"
#include "config.h"
int setup_config(Config *conf, char **hostname, char **fs)
{
	if (*hostname == NULL) {
		*hostname = "nucleus";
	}
	if (strlen(*hostname) > 64) {
		errno = NUC_HOST_NAME_ERR;
		return -1;
	}
	conf->hostname = *hostname;
	// TODO: check the rootfs properly when we do the file-system properly.
	// for now just check the path exist or not. we are not checking the
	// contents inside it.
	struct stat st;
	if (stat(*fs, &st) != 0 || S_ISDIR(st.st_mode) == 0) {
		errno = NUC_INVALID_ROOTFS_PATH;
		return -1;
	}
	conf->root_fs = *fs;
	return 0;
}