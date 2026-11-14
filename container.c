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
#include "nuc_error.h"
int pivot_root(const char *new_root, const char *put_old)
{
	return syscall(SYS_pivot_root, new_root, put_old);
}
int container(void *arg)
{
	Config *conf = arg;
	char buf;
	close(conf->sync_fd[1]);

	if (read(conf->sync_fd[0], &buf, 1) != 1) {
		nuc_err_report("read from pipe", errno);
		_exit(125);
	}
	signal(SIGPIPE, SIG_DFL);
	if (mount("", "/", NULL, MS_REC | MS_PRIVATE, NULL) == -1) {
		nuc_err_report("mount private", errno);
		_exit(125);
	}
	char *olddir = "/olddir";
	char *old_fs = malloc(strlen(conf->root_fs) + strlen(olddir) + 1);
	if (old_fs == NULL) {
		nuc_err_report("malloc container", errno);
		_exit(125);
	}
	strcpy(old_fs, conf->root_fs);
	strcat(old_fs, olddir);

	if (mount(conf->root_fs, conf->root_fs, NULL, MS_BIND | MS_REC, 0) ==
	    -1) {
		nuc_err_report("bind rootfs", errno);
		_exit(125);
	}
	if (mkdir(old_fs, 0755) == -1) {
		if (errno != EEXIST) {
			nuc_err_report("create olddir", errno);
			_exit(125);
		}
	}

	if (pivot_root(conf->root_fs, old_fs) == -1) {
		nuc_err_report("mount new rootfs", errno);
		_exit(125);
	}
	free(old_fs);
	if (chdir("/") == -1) {
		nuc_err_report("change dir", errno);
		_exit(125);
	}

	if (mount("nucleusproc", "/proc", "proc", 0, NULL) == -1) {
		nuc_err_report("mount proc", errno);
		_exit(125);
	}
	if (umount2(olddir, MNT_DETACH) == -1) {
		nuc_err_report("unmount olddir", errno);
		_exit(125);
	}
	if (rmdir(olddir) == -1) {
		nuc_err_report("remove olddir", errno);
		_exit(125);
	}
	size_t len = strlen(conf->hostname);
	if (sethostname(conf->hostname, len) == -1) {
		nuc_err_report("sethostname", errno);
		_exit(125);
	}
	execlp("/bin/sh", "sh", NULL);
	nuc_err_report("exec", errno);
	_exit(125);
}