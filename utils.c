#include <stdlib.h>
#include <fcntl.h>
#include <stdio.h>
#include <unistd.h>
#include "utils.h"
int write_file(char *path, char *what, size_t len)
{
	int fd = open(path, O_WRONLY);
	if (fd == -1) {
		perror("failed to open the file");
		return -1;
	}
	if (write(fd, what, len) != (ssize_t)len) {
		perror("failed to write to file");
		close(fd);
		return -1;
	}
	close(fd);
	return 0;
}