#ifndef XYMON_PCRE_H
#define XYMON_PCRE_H

#ifdef XYMON_USE_PCRE2

#ifndef PCRE2_CODE_UNIT_WIDTH
#define PCRE2_CODE_UNIT_WIDTH 8
#endif

#include <limits.h>
#include <pcre2.h>
#include <string.h>

typedef pcre2_code pcre;
typedef void pcre_extra;

#ifndef PCRE_CASELESS
#define PCRE_CASELESS PCRE2_CASELESS
#endif

#ifndef PCRE_MULTILINE
#define PCRE_MULTILINE PCRE2_MULTILINE
#endif

#ifndef PCRE_FIRSTLINE
#define PCRE_FIRSTLINE PCRE2_FIRSTLINE
#endif

#ifndef PCRE_ERROR_NOMATCH
#define PCRE_ERROR_NOMATCH (-1)
#endif

static inline pcre *pcre_compile(const char *pattern, int options, const char **errmsg, int *erroffset, const unsigned char *tableptr)
{
	static char errbuf[256];
	int errnum = 0;
	PCRE2_SIZE errofs = 0;
	pcre2_code *code;

	(void)tableptr;

	code = pcre2_compile((PCRE2_SPTR)pattern, PCRE2_ZERO_TERMINATED, (uint32_t) options, &errnum, &errofs, NULL);
	if (!code) {
		if (errmsg) {
			if (pcre2_get_error_message(errnum, (PCRE2_UCHAR *)errbuf, sizeof(errbuf)) < 0) {
				strcpy(errbuf, "PCRE2 compile error");
			}
			*errmsg = errbuf;
		}
		if (erroffset) *erroffset = (int) errofs;
		return NULL;
	}

	if (errmsg) *errmsg = NULL;
	if (erroffset) *erroffset = 0;
	return (pcre *) code;
}

static inline int pcre_exec(const pcre *code, const pcre_extra *extra, const char *subject, int length, int startoffset, int options, int *ovector, int ovecsize)
{
	pcre2_match_data *mdata;
	PCRE2_SIZE *ov;
	int i, copycount;
	int rc;

	(void)extra;

	if (!code || !subject) return PCRE_ERROR_NOMATCH;

	mdata = pcre2_match_data_create_from_pattern((const pcre2_code *)code, NULL);
	if (!mdata) return PCRE_ERROR_NOMATCH;

	rc = pcre2_match((const pcre2_code *)code, (PCRE2_SPTR)subject, (PCRE2_SIZE)length, (PCRE2_SIZE)startoffset, (uint32_t) options, mdata, NULL);
	if (rc >= 0 && ovector && (ovecsize > 0)) {
		ov = pcre2_get_ovector_pointer(mdata);
		copycount = rc * 2;
		if (copycount > ovecsize) copycount = ovecsize;
		for (i = 0; (i < copycount); i++) {
			if (ov[i] > (PCRE2_SIZE)INT_MAX) {
				pcre2_match_data_free(mdata);
				return PCRE_ERROR_NOMATCH;
			}
			ovector[i] = (int)ov[i];
		}
	}

	pcre2_match_data_free(mdata);
	if (rc == PCRE2_ERROR_NOMATCH) return PCRE_ERROR_NOMATCH;
	return rc;
}

static inline int pcre_copy_substring(const char *subject, int *ovector, int stringcount, int stringnumber, char *buffer, int buffersize)
{
	int start, end, len;

	if (!subject || !ovector || !buffer || (buffersize <= 0)) return -1;
	if ((stringnumber < 0) || (stringnumber >= stringcount)) return -1;

	start = ovector[(2 * stringnumber)];
	end = ovector[(2 * stringnumber) + 1];
	if ((start < 0) || (end < start)) return -1;

	len = (end - start);
	if (len >= buffersize) return -1;

	memcpy(buffer, (subject + start), len);
	buffer[len] = '\0';
	return len;
}

static inline void pcre_free(void *ptr)
{
	if (ptr) pcre2_code_free((pcre2_code *)ptr);
}

#else

#include <pcre.h>

#endif

#endif
