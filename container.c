#include <sys/mount.h>
#include <string.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <stdio.h>
#include <unistd.h>
#include <sched.h>
#include <sys/wait.h>
#include <errno.h>
#include <stdlib.h>
#include "config.h"
int pivot_root(const char *new_root, const char *put_old)
{
	return syscall(SYS_pivot_root, new_root, put_old);
}
int container(void *arg)
{
	Config *conf = arg;
	char buf;
	if (read(conf->sync_fd[0], &buf, 1) != 1) {
		perror("read from fd failed");
		exit(EXIT_FAILURE);
	}

	if (mount("", "/", NULL, MS_REC | MS_PRIVATE, NULL) == -1) {
		perror("failed to make the child mount table private");
		return 1;
	}
	char *olddir = "/olddir";
	char *old_fs = malloc(strlen(conf->root_fs) + strlen(olddir) + 1);
	if (old_fs == NULL) {
		perror("malloc failed");
		return 1;
	}
	strcpy(old_fs, conf->root_fs);
	strcat(old_fs, olddir);

	if (mount(conf->root_fs, conf->root_fs, NULL, MS_BIND | MS_REC, 0) ==
	    -1) {
		perror("binding root dir failed");
		return 1;
	}
	if (mkdir(old_fs, 0755) == -1) {
		if (errno != EEXIST) {
			perror("failed to create old dir");
			return 1;
		}
	}

	if (pivot_root(conf->root_fs, old_fs) == -1) {
		perror("mounting new root failed");
		return 1;
	}
	free(old_fs);
	if (chdir("/") == -1) {
		perror("failed to change the working directory");
		return 1;
	}

	if (mount("nucleusproc", "/proc", "proc", 0, NULL) == -1) {
		perror("mounting failed");
		return 1;
	}
	if (umount2(olddir, MNT_DETACH) == -1) {
		perror("failed to unmount the old dir");
		return 1;
	}
	if (rmdir(olddir) == -1) {
		perror("failed to delete the olddir directory");
		return 1;
	}
	size_t len = strlen(conf->hostname);
	if (sethostname(conf->hostname, len) == -1) {
		perror("sethostname failed");
		return (1);
	}
	printf("hostname set successfully\n");
	execlp("/bin/sh", "sh", NULL);
	perror("exec failed");
	return (1);
}