/*----------------------------------------------------------------------------*/
/* Xymon RRD graph generator - instance key ordering.                         */
/*                                                                            */
/* One version-aware TOTAL order for instance keys, shared between            */
/* showgraph.c and its unit test by #include (the aggregate-tokens.inc.c      */
/* pattern). Replaces the old two-regime comparator (whole-key numeric vs     */
/* strcmp), whose per-pair regime choice was intransitive - qsort output      */
/* depended on readdir order - and which compared distinct keys ("007" vs     */
/* "7") as equal, making their slice membership unspecified.                  */
/*                                                                            */
/* Piecewise comparison, strverscmp-family: where both keys have a digit      */
/* run, the runs compare numerically (fewer leading zeros first on ties,     */
/* then byte order, so distinct keys never compare equal); everywhere else    */
/* bytes compare directly. Subsumes all prior cases: plain integers sort      */
/* numerically, OID/version keys ("1.2.10" vs "1.10.1") sort by component,   */
/* names sort byte-wise.                                                      */
/*----------------------------------------------------------------------------*/

static int instance_key_compare(const char *a, const char *b)
{
	while (*a && *b) {
		if (isdigit((unsigned char)*a) && isdigit((unsigned char)*b)) {
			const char *as = a, *bs = b;
			size_t araw = 0, braw = 0, alen, blen, i;

			while (isdigit((unsigned char)a[araw])) araw++;
			while (isdigit((unsigned char)b[braw])) braw++;
			while (*as == '0') as++;
			while (*bs == '0') bs++;
			alen = (size_t)(a + araw - as);
			blen = (size_t)(b + braw - bs);

			/* numeric magnitude: more significant digits = greater */
			if (alen != blen) return (alen < blen ? -1 : 1);
			for (i = 0; (i < alen); i++) {
				if (as[i] != bs[i]) return (as[i] < bs[i] ? -1 : 1);
			}
			/* equal magnitude: tie-break on leading zeros (fewer
			 * first), so "007" and "7" never compare equal */
			if (araw != braw) return (araw < braw ? -1 : 1);
			a += araw; b += braw;
		}
		else if (*a != *b) {
			return ((unsigned char)*a < (unsigned char)*b ? -1 : 1);
		}
		else { a++; b++; }
	}
	if (*a) return 1;
	if (*b) return -1;
	return 0;
}
