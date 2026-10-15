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

/* The values of the verdict columns that follow the samples, from the
 * "losshour= lossstate= losswarn= losscrit=" fields xymonnet adds to a
 * smoke host's ping line (fractions, the state 0 green 1 yellow 2 red):
 * ":<v>:<v>:<v>:<v>", "U" for each absent or malformed. Appended by the
 * caller to the smokeping_format_rrdvalues*() string. Returns bytes
 * written, or -1 when out is too small. */
int smokeping_format_verdict(const char *msg, char *out, int outlen);

/* ---- Loss judgement -------------------------------------------------- */

/* One run of a smoke host, kept between xymonnet runs: when, how many
 * pings were lost of how many sent, and the run's median and spread
 * (p90 - p50) in seconds, NAN when nothing came back. */
typedef struct smoke_run_t {
	time_t t;
	int lost, sent;
	double median, spread;
} smoke_run_t;

#define SMOKE_MAXRUNS 64

/* A host's recent runs, oldest first, and the verdicts carried from one
 * run to the next: the hour's state (0 green, 1 yellow, 2 red), for
 * the levels' hysteresis, and whether the last run was a burst. */
typedef struct smoke_hist_t {
	int nruns;
	smoke_run_t run[SMOKE_MAXRUNS];
	int hourstate;
	int burst;
} smoke_hist_t;

/* The levels a host is judged by, in percent of the pings sent; 0
 * disables a level. */
typedef struct smoke_levels_t {
	double warn, crit, burst;
} smoke_levels_t;

/* What one judgement found. state is the column's colour from loss:
 * 0 green, 1 yellow, 2 red. */
typedef struct smoke_verdict_t {
	int state;
	int hourlost, hoursent;		/* over the window */
	int judged;			/* the window held enough pings */
	int burst;			/* this run reached the burst level */
} smoke_verdict_t;

/* The history as one line - "<hourstate> <burst> t:lost:sent:median:spread ..." -
 * and back. Parsing ignores what it does not recognise and returns the
 * number of runs read. */
int smokeping_hist_format(const smoke_hist_t *h, char *out, int outlen);
int smokeping_hist_parse(const char *line, smoke_hist_t *h);

/* Add a run, dropping the runs older than `window` seconds before it. */
void smokeping_hist_add(smoke_hist_t *h, const smoke_run_t *run, time_t window);

/* Judge the loss of the window ending with the newest run:
 *   - over the window, once it holds `minpings`: red at crit, yellow at
 *     warn; a level reached clears only below two thirds of it;
 *   - the newest run losing burst% or more is at least yellow, and red
 *     when the run before it did too.
 * The colour is the worse of the two. Updates h->hourstate and
 * h->burst for the next run. */
void smokeping_judge(smoke_hist_t *h, time_t window, int minpings,
                     const smoke_levels_t *lv, smoke_verdict_t *v);

#endif
