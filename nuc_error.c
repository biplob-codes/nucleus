#include <string.h>
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