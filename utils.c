#include <stdlib.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include <errno.h>
#include "utils.h"
int write_file(char *path, char *what, size_t len)
{
	int fd = open(path, O_WRONLY);
	if (fd == -1)
		return -1;

	if (write(fd, what, len) != (ssize_t)len) {
		int save = errno;
		close(fd);
		errno = save;
		return -1;
	}
	close(fd);
	return 0;
}