#include <string.h>
#include "parser.h"
void parse(int argc, char *argv[], char **hostname)
{
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0) {
			if (i + 1 < argc) {
				*hostname = argv[i + 1];
			}
		}
	}
}