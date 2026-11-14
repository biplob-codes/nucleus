#include <string.h>
#include <errno.h>
#include "parser.h"
#include "nuc_error.h"
int parse(int argc, char *argv[], char **hostname, char **fs)
{
	int essential_flags_found = 0;
	for (int i = 1; i < argc; i++) {
		if (strcmp(argv[i], "-h") == 0) {
			if (i + 1 < argc) {
				*hostname = argv[i + 1];
			}
		}
		if (strcmp(argv[i], "-fs") == 0) {
			if (i + 1 < argc) {
				*fs = argv[i + 1];
				essential_flags_found = 1;
			}
		}
	}
	if (essential_flags_found == 0) {
		errno = NUC_E_MISSING_FLAGS;
		return -1;
		}
	return 0;
}