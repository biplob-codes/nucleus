#include <string.h>
#include <errno.h>
#include <stdio.h>
#include "nuc_error.h"
char *err_str(int e)
{
	switch (e) {
	case NUC_E_MISSING_FLAGS:
		return "missing the necessary flags to start the programm";
	default:
		return strerror(e);
	}
}

void nuc_err_report(char *step, int e)
{
	fprintf(stderr, "%s: %s\n", step, err_str(e));
}