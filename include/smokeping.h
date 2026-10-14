/*----------------------------------------------------------------------------*/
/* Xymon SmokePing helpers                                                    */
/*                                                                            */
/* Parsing and RRD-schema helpers for SmokePing-style multi-sample probing.   */
/* Used by xymond_rrd handlers that consume status messages emitted by        */
/* probes like xymonping(1) --samples=N, where each cycle reports raw         */
/* per-sample rtts plus a loss tally:                                         */
/*                                                                            */
/*   <ip> is alive (<avg ms>) samples=v1,v2,...,vM loss=K/N                   */
/*   <ip> is unreachable loss=N/N                                             */
/*                                                                            */
/* Designed to be the single source of truth for the RRD layout and the       */
/* parser, so a future second smoke probe (DNS smoke, HTTP smoke, ...) can    */
/* share both without copy-pasting do_net_rrd's PINGCOLUMN branch.            */
/*----------------------------------------------------------------------------*/
#ifndef _SMOKEPING_H_
#define _SMOKEPING_H_

#include <sys/types.h>
#include <time.h>

/* Hard upper bound on N (loss=K/N denominator) accepted by the RRD
 * worker. Mirrors xymonping's MAX_SAMPLES_PER_HOST so a producer
 * staying within its own cap is always accepted, while a malformed or
 * hostile status line can't trigger a giant allocation here. */
#define SMOKEPING_MAX_SAMPLES 1000

/* Configured per-cycle sample count. Reads $SMOKEPINGSAMPLES once and
 * caches the result; defaults to 20 if unset or non-positive. */
int smokeping_sample_count(void);

/* NULL-terminated array of rrdtool DS specs for a smoke RRD with `n`
 * per-cycle samples: DS:median, DS:loss, DS:ping1..pingN. Per-N cache;
 * do not free. _n() is the explicit variant; the zero-arg form is a
 * convenience wrapper using smokeping_sample_count().
 *
 * Thread-safety: the per-N cache is a single linked list mutated
 * without locking; safe in the single-threaded xymond_rrd worker that
 * is the only current caller. If a future caller is multi-threaded
 * (alerting daemon etc.), wrap cache_lookup_or_create in a mutex. */
char **smokeping_rrd_params_n(int n);
char **smokeping_rrd_params(void);

/* setup_template()-built handle for the smoke RRD params. Per-N cache. */
void *smokeping_rrd_template_n(int n);
void *smokeping_rrd_template(void);

/* Parse a smoke-style message:
 *   - returns 1 if "loss=" is present (smoke marker), 0 otherwise
 *   - parses optional "samples=v1,..,vM" into samples_out (input order)
 *   - parses "loss=K/N" into *lost_out and *total_out
 * samples_out must have room for samples_max doubles. */
int smokeping_parse_message(const char *msg, double *samples_out,
                            int samples_max, int *received_out,
                            int *lost_out, int *total_out);

/* Turn one summary line of fping's count mode ("fping -C N -q", which
 * prints it on stderr):
 *   <ip> : <ms> <ms> - <ms>
 * into the xymonping --samples line the parser above reads:
 *   <ip> is alive (<avg> ms) samples=<s>,<s>,<s> loss=1/4
 *   <ip> is unreachable loss=4/4
 * "-" is a lost ping; fping's times are milliseconds, the samples are
 * seconds. Returns 1 when `line` is such a summary and the result fits
 * in `out`, else 0 (fping's error lines, for one). */
int smokeping_from_fping_count(const char *line, char *out, int outlen);

/* Sorts samples[0..received-1] ascending in place and returns the
 * median. Returns NAN when received == 0. */
double smokeping_median(double *samples, int received);

/* Format an rrdvalues string suitable for create_and_update_rrd():
 *   "<tstamp>:<median|U>:<lossfrac>:<s1>:<s2>:...:<sN>"
 * with `n_slots` ping slots. sorted_samples must be ascending. When
 * received < n_slots the lost pings are "U", half below the samples and
 * half above (the odd one above), as SmokePing stores them: the smoke
 * pairs slot i with slot N+1-i, and centring keeps the samples it pairs
 * the fastest and slowest received.
 * The zero-arg-N form uses smokeping_sample_count().
 * Returns bytes written (excluding NUL). */
int smokeping_format_rrdvalues_n(char *out, int outlen, time_t tstamp,
                                 double median, double lossfrac,
                                 const double *sorted_samples,
                                 int received, int n_slots);
int smokeping_format_rrdvalues(char *out, int outlen, time_t tstamp,
                               double median, double lossfrac,
                               const double *sorted_samples,
                               int received);

#endif
