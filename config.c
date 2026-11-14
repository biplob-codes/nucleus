#include <stdlib.h>
#include <sys/stat.h>
#include <stdio.h>
#include "config.h"
int setup_config(Config *conf, char **hostname, char **fs)
{
	if (*hostname == NULL) {
		*hostname = "nucleus";
	}
	conf->hostname = *hostname;
	struct stat st;
	if (stat(*fs, &st) != 0) {
		return -1;
		// fprintf(stderr, "fs doesnt exist or inaccessible\n");
		// exit(EXIT_FAILURE);
	}
	if (S_ISDIR(st.st_mode) == 0) {
		return -1;
		// fprintf(stderr, "fs is not a directory\n");
		// exit(EXIT_FAILURE);
	}
	conf->root_fs = *fs;
	return 0;
}