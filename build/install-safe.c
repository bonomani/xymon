/* SPDX-License-Identifier: GPL-2.0-or-later */
/*
 * build/install-safe.c -- install a file, or set the owner and mode of a name,
 * as root into a directory owned by an unprivileged user, without following a
 * symlink at the destination name and without a check-then-act race.
 *
 * The install runs as root and writes into directories that are later owned by
 * the Xymon user. A destination name may be a symlink -- a relocation left by a
 * moved install directory, or one present from an earlier install -- and a plain
 * cp/chown/chmod/touch follows it and acts on the link's target instead of the
 * name. The shell install guards each call site by hand (rm -f before cp, -h on
 * chown, "test -L ||" before chmod, ...), in several styles and at ~170 sites,
 * and still leaves a window between a check and the act. This one helper does
 * each operation once, safely and atomically, so every call site is one obvious
 * invocation.
 *
 * Usage (one verb per call):
 *   install-safe copy  -m MODE [-o OWNER] [-g GROUP] SRC DEST   install SRC as DEST
 *   install-safe mkdir [-m MODE] [-o OWNER] [-g GROUP] DIR      create DIR if absent, own/mode it
 *   install-safe touch [-m MODE] [-o OWNER] [-g GROUP] NAME     create NAME if absent, own/mode it
 *   install-safe set   [-m MODE] [-o OWNER] [-g GROUP] NAME     set owner/mode of an existing NAME
 *
 * MODE is octal (required for copy). OWNER/GROUP are a name or a numeric id. A
 * setuid/setgid MODE is allowed only with copy, and only when the file ends up
 * root-owned (an unprivileged owner could rewrite its content before the mode
 * is set), never with mkdir/set.
 *
 * How it is safe:
 *   copy          -- the content is written to a fresh O_CREAT|O_EXCL|O_NOFOLLOW
 *                    temporary in DEST's directory (so the name cannot be a
 *                    pre-existing symlink), owner then mode set on the open fd,
 *                    fsync'd, rename()d over DEST, and the result confirmed by fd
 *                    to be the file just written. rename replaces a symlink at
 *                    DEST atomically and follows nothing.
 *   owner/mode    -- the name is lstat'd first: a symlink is left untouched (its
 *                    relocation is preserved), anything that is not a plain
 *                    singly-linked file (for set) or a directory (for mkdir) is
 *                    refused rather than opened, and only then is it opened with
 *                    O_NOFOLLOW and operated on by fd, the fd confirmed to be the
 *                    object lstat saw.
 *
 * Not covered (a non-goal, as the shell guards are too): an *intermediate*
 * directory in the path being a symlink that user placed. The parent chain
 * of a destination must not be writable by the unprivileged user; the Xymon
 * layout keeps the roots ($XYMONHOME, $XYMONVAR, ...) under root-owned parents.
 * Closing that too needs a component-by-component openat resolution with the
 * fchownat/fchmodat/renameat family against a trusted directory fd.
 *
 * Two further limits are inherent to acting on a name, not defects:
 *   - set and mkdir act on whatever object holds the name at the instant they run.
 *     The owner of the directory can rename a different root-owned object in the
 *     same directory onto the name first. So set must not be relied on to grant
 *     privilege to an existing name; anything that must end up root-owned is put
 *     there as a fresh file (plain install), never adjusted in place with set.
 *   - SRC is read from the trusted build tree and its symlinks are followed; the
 *     build tree must not be writable by the unprivileged user.
 *   - A setuid/setgid copy into a directory the unprivileged user owns can be
 *     captured: the file is complete and correct, but the directory owner can
 *     rename it aside right after the rename and keep the setuid inode. The
 *     content is the trusted source, so this grants no new code, only a setuid
 *     copy of a Xymon binary; installing a setuid program into a root-owned
 *     directory, or an openat-from-a-trusted-dirfd placement, avoids it.
 */

/* Each Unix gates fchown, fchmod, lchown and SIGXFSZ behind a different
 * feature-test macro. The pure BSDs expose them only WITHOUT a strict
 * _POSIX_C_SOURCE (NetBSD hides fchown/fchmod under it, FreeBSD hides SIGXFSZ);
 * AIX and HP-UX expose them only WITH their own extensions macro; glibc, Solaris
 * and macOS expose them under _POSIX_C_SOURCE. */
#if defined(_AIX)
#  define _ALL_SOURCE
#elif defined(__hpux)
#  define _HPUX_SOURCE
#elif defined(__FreeBSD__) || defined(__NetBSD__) || defined(__OpenBSD__) || defined(__DragonFly__)
/* The BSDs hide fchown/fchmod/SIGXFSZ under a strict _POSIX_C_SOURCE; clear one
 * a caller's CFLAGS may have predefined, rather than only refraining from it. */
#  undef _POSIX_C_SOURCE
#  undef _XOPEN_SOURCE
#else
#  define _POSIX_C_SOURCE 200809L
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <ctype.h>
#include <signal.h>
#include <limits.h>
#include <sys/stat.h>
#include <pwd.h>
#include <grp.h>

#ifndef O_NOFOLLOW
#define O_NOFOLLOW 0		/* best effort; the lstat/fstat check below still refuses a symlink */
#endif
#ifndef O_NOCTTY
#define O_NOCTTY 0
#endif
#ifndef O_NONBLOCK
#define O_NONBLOCK 0
#endif

static const char *prog = "install-safe";

/* The temporary file in progress, so a signal can remove it. */
static char g_tmp[PATH_MAX + 32];
static volatile sig_atomic_t g_have_tmp = 0;

static void cleanup_tmp(void)
{
	if (g_have_tmp) (void)unlink(g_tmp);
}

static void on_signal(int sig)
{
	cleanup_tmp();
	_exit(128 + sig);
}

static void die(const char *what, const char *name)
{
	int e = errno;
	cleanup_tmp();
	fprintf(stderr, "%s: %s %s: %s\n", prog, what, name ? name : "", strerror(e));
	exit(1);
}

/* An O_NOFOLLOW open of a symlink reports ELOOP on most systems, EMLINK on a
 * few. isdir is unused here but kept for a possible O_DIRECTORY ENOTDIR case. */
static int is_symlink_open_errno(int e, int isdir)
{
	(void)isdir;
	return e == ELOOP
#ifdef EMLINK
	    || e == EMLINK
#endif
#ifdef EFTYPE
	    || e == EFTYPE	/* NetBSD returns this for O_NOFOLLOW on a symlink */
#endif
	    ;
}

/* A trailing '/', or a final "." or "..", makes open(O_NOFOLLOW) and lstat both
 * resolve through a symlink at the last real component, defeating the no-follow
 * guarantee. Refuse such names; a caller names the object itself. */
static void reject_bad_name(const char *name)
{
	size_t l = strlen(name);
	const char *b = strrchr(name, '/');
	b = b ? b + 1 : name;
	if (l == 0 || name[l - 1] == '/' || strcmp(b, ".") == 0 || strcmp(b, "..") == 0) {
		fprintf(stderr, "%s: refusing a name ending in '/', '.' or '..': %s\n", prog, name);
		exit(2);
	}
}

static long parse_octal(const char *s)
{
	char *end;
	long v;
	if (!isdigit((unsigned char)*s)) { fprintf(stderr, "%s: bad mode: %s\n", prog, s); exit(2); }
	errno = 0;
	v = strtol(s, &end, 8);
	if (errno != 0 || end == s || *end != '\0' || v < 0 || v > 07777) {
		fprintf(stderr, "%s: bad mode: %s\n", prog, s);
		exit(2);
	}
	return v;
}

static unsigned long parse_id(const char *s)
{
	char *end;
	unsigned long v;
	/* The caller admits only a leading digit, so no sign reaches strtoul. The
	 * representability and sentinel checks are applied against the target type. */
	errno = 0;
	v = strtoul(s, &end, 10);
	if (errno != 0 || end == s || *end != '\0') {
		fprintf(stderr, "%s: bad numeric id: %s\n", prog, s);
		exit(2);
	}
	return v;
}

static uid_t lookup_user(const char *s)
{
	struct passwd *pw;
	if (!s) return (uid_t)-1;
	if ((pw = getpwnam(s)) != NULL) {
		if (pw->pw_uid == (uid_t)-1) { fprintf(stderr, "%s: user %s has the reserved id\n", prog, s); exit(2); }
		return pw->pw_uid;
	}
	if (isdigit((unsigned char)*s)) {
		unsigned long v = parse_id(s);
		uid_t u = (uid_t)v;
		/* Reject an id that does not survive the cast to uid_t (a narrower type
		 * on some platforms), or that is the (uid_t)-1 "do not change" sentinel. */
		if ((unsigned long)u != v || u == (uid_t)-1) { fprintf(stderr, "%s: uid out of range: %s\n", prog, s); exit(2); }
		return u;
	}
	fprintf(stderr, "%s: no such user: %s\n", prog, s);
	exit(2);
}

static gid_t lookup_group(const char *s)
{
	struct group *gr;
	if (!s) return (gid_t)-1;
	if ((gr = getgrnam(s)) != NULL) {
		if (gr->gr_gid == (gid_t)-1) { fprintf(stderr, "%s: group %s has the reserved id\n", prog, s); exit(2); }
		return gr->gr_gid;
	}
	if (isdigit((unsigned char)*s)) {
		unsigned long v = parse_id(s);
		gid_t g = (gid_t)v;
		if ((unsigned long)g != v || g == (gid_t)-1) { fprintf(stderr, "%s: gid out of range: %s\n", prog, s); exit(2); }
		return g;
	}
	fprintf(stderr, "%s: no such group: %s\n", prog, s);
	exit(2);
}

/* Set owner (always) and mode on an existing name, without following a symlink
 * at it. A symlink is left untouched; a non-plain / non-directory name, or one
 * that changes under us, is refused. */
static void set_owner_and_mode(const char *name, uid_t uid, gid_t gid, long mode, int isdir)
{
	int want_owner = (uid != (uid_t)-1 || gid != (gid_t)-1);
	int flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY;
	struct stat lst, fst;
	int fd;

	if (lstat(name, &lst) != 0) die("cannot stat", name);

	/* A symlink at the name: its relocation is the admin's, do not touch it --
	 * but for mkdir confirm the directory actually exists through it. */
	if (S_ISLNK(lst.st_mode)) {
		if (isdir) {
			struct stat ts;
			if (stat(name, &ts) != 0 || !S_ISDIR(ts.st_mode)) { errno = ENOTDIR; die("directory name is a symlink not pointing to a directory", name); }
		}
		return;
	}

	/* Classify before opening, so a fifo/device at the name is never opened
	 * (which could block or have a side effect). */
	if (isdir) {
		if (!S_ISDIR(lst.st_mode)) { errno = ENOTDIR; die("not a directory", name); }
	} else if (!S_ISREG(lst.st_mode) || lst.st_nlink != 1) {
		errno = EPERM;
		die("not a plain, singly-linked file", name);
	}

#ifdef O_DIRECTORY
	if (isdir) flags |= O_DIRECTORY;
#endif
	fd = open(name, flags);
	if (fd < 0) die("cannot open", name);	/* a swap to a symlink since lstat -> ELOOP here */
	if (fstat(fd, &fst) != 0) { close(fd); die("cannot stat", name); }

	/* The open must have landed on the very object lstat saw (catches a build
	 * without O_NOFOLLOW, and a swap between the lstat and the open). */
	if (fst.st_dev != lst.st_dev || fst.st_ino != lst.st_ino) {
		close(fd);
		errno = EAGAIN;
		die("name changed under the install", name);
	}
	if (!isdir && fst.st_nlink != 1) { close(fd); errno = EPERM; die("not a singly-linked file", name); }
	/* Re-check the type on the fd: dev/ino equality can be met by a reused inode
	 * number (an ABA swap), so confirm the open object is still the kind lstat saw. */
	if (isdir ? !S_ISDIR(fst.st_mode) : !S_ISREG(fst.st_mode)) { close(fd); errno = EPERM; die("type changed under the install", name); }

	/* Owner before mode, so a later chown cannot clear a setuid/setgid bit. */
	if (want_owner && fchown(fd, uid, gid) != 0) { close(fd); die("cannot set owner of", name); }
	if (mode >= 0) {
		if (fchmod(fd, (mode_t)mode) != 0) { close(fd); die("cannot set mode of", name); }
	} else if (!isdir) {
		/* set with no -m must not leave a setuid/setgid bit on a name it set in
		 * place (a root chown does not clear it on every platform; a config is
		 * never setuid). Re-stat after the fchown so the decision is on the
		 * current bits, not ones that may have changed since the first fstat. */
		struct stat p;
		if (fstat(fd, &p) != 0) { close(fd); die("cannot stat", name); }
		if ((p.st_mode & 06000) && fchmod(fd, p.st_mode & 01777) != 0) { close(fd); die("cannot clear setuid of", name); }
	}
	if (close(fd) != 0) die("close failed on", name);
}

/* Ensure a plain file exists at NAME (create it empty if absent, keep its
 * content if present), then set owner/mode, without following a symlink. A
 * symlink at the name is left untouched (an admin relocation). */
static void ensure_file(const char *name, uid_t uid, gid_t gid, long mode)
{
	struct stat lst, fst;
	int fd, tries;

	/* Classify by lstat first, exactly as set_owner_and_mode does, so nothing is
	 * created or opened through a symlink even on a build without O_NOFOLLOW. A
	 * name that races in between the lstat and the create/open is re-classified,
	 * bounded: a file that appears after the lstat is still given its owner and
	 * mode, rather than reported done untouched, and a name flipped repeatedly
	 * fails loudly instead of succeeding silently or spinning. */
	for (tries = 0; tries <= 8; tries++) {
		if (lstat(name, &lst) != 0) {
			if (errno != ENOENT) die("cannot stat", name);	/* e.g. a parent symlink loop: refuse */

			/* Absent: create it fresh. O_EXCL refuses a symlink or any name
			 * that raced into existence (so a symlink that appeared cannot
			 * be followed), with or without O_NOFOLLOW. */
			fd = open(name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600);
			if (fd >= 0) {
				/* A new file can inherit the directory's group (setgid dir, or
				 * BSD): set the group to root's even without -g, as
				 * install_file does. */
				if (gid == (gid_t)-1) gid = getegid();
				if (fchown(fd, uid, gid) != 0) { close(fd); die("cannot set owner of", name); }
				if (mode >= 0 && fchmod(fd, (mode_t)mode) != 0) { close(fd); die("cannot set mode of", name); }
				if (close(fd) != 0) die("close failed on", name);
				return;
			}
			if (is_symlink_open_errno(errno, 0)) return;	/* a symlink raced in: leave it */
			if (errno != EEXIST) die("cannot create", name);
			continue;	/* a non-symlink raced in (EEXIST): re-classify and set it below */
		}

		/* A symlink at the name: leave its relocation, as set does. */
		if (S_ISLNK(lst.st_mode)) return;
		if (!S_ISREG(lst.st_mode) || lst.st_nlink != 1) { errno = EPERM; die("not a plain, singly-linked file", name); }

		/* Exists as a plain file: open it (no create, no truncate), confirm the
		 * fd is that object, and set owner/mode by fd. */
		fd = open(name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_NOCTTY);
		if (fd < 0) {
			if (errno == ENOENT) continue;	/* vanished after the lstat: start over */
			die("cannot open", name);
		}
		if (fstat(fd, &fst) != 0) { close(fd); die("cannot stat", name); }
		if (fst.st_dev != lst.st_dev || fst.st_ino != lst.st_ino) { close(fd); errno = EAGAIN; die("name changed under the install", name); }
		if (!S_ISREG(fst.st_mode) || fst.st_nlink != 1) { close(fd); errno = EPERM; die("not a plain, singly-linked file", name); }
		if ((uid != (uid_t)-1 || gid != (gid_t)-1) && fchown(fd, uid, gid) != 0) { close(fd); die("cannot set owner of", name); }
		if (mode >= 0) {
			if (fchmod(fd, (mode_t)mode) != 0) { close(fd); die("cannot set mode of", name); }
		} else {
			/* No -m: do not leave a setuid/setgid bit. Re-stat after the fchown
			 * so the decision is on the current bits, not ones that changed. */
			struct stat p;
			if (fstat(fd, &p) != 0) { close(fd); die("cannot stat", name); }
			if ((p.st_mode & 06000) && fchmod(fd, p.st_mode & 01777) != 0) { close(fd); die("cannot clear setuid of", name); }
		}
		if (close(fd) != 0) die("close failed on", name);
		return;
	}
	errno = EAGAIN;
	die("name keeps changing under the install", name);
}

static void install_file(const char *src, const char *dest, uid_t uid, gid_t gid, long mode)
{
	int sfd, tfd;
	char buf[65536];
	ssize_t n;
	struct stat fst, lst, sst;

	if ((size_t)snprintf(g_tmp, sizeof g_tmp, "%s.inst.%ld", dest, (long)getpid()) >= sizeof g_tmp)
		{ fprintf(stderr, "%s: destination path too long: %s\n", prog, dest); exit(1); }

	/* O_NONBLOCK so a fifo SRC cannot hang; require a regular source. */
	if ((sfd = open(src, O_RDONLY | O_NONBLOCK | O_NOCTTY)) < 0) die("cannot read", src);
	if (fstat(sfd, &sst) != 0) { close(sfd); die("cannot stat", src); }
	if (!S_ISREG(sst.st_mode)) { close(sfd); errno = EINVAL; die("source is not a regular file", src); }

	/* O_EXCL refuses any existing name (so it cannot be a symlink left at the name, which
	 * O_NOFOLLOW also refuses); the temp is created root-owned 0600. Mark it for
	 * signal cleanup before the create so an interrupt mid-create still removes
	 * it. */
	(void)unlink(g_tmp);
	g_have_tmp = 1;
	/* Mode 0: unopenable by anyone but root until the final fchmod, so the owner
	 * set by fchown cannot grab a writable fd in the fchown->fchmod window (copy
	 * always sets a mode, so the file never stays 0). */
	if ((tfd = open(g_tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0)) < 0) {
		g_have_tmp = 0;
		close(sfd);
		die("cannot create temporary at", g_tmp);
	}

	while ((n = read(sfd, buf, sizeof buf)) > 0) {
		char *p = buf;
		while (n > 0) {
			ssize_t w = write(tfd, p, (size_t)n);
			if (w < 0) { if (errno == EINTR) continue; close(tfd); close(sfd); die("write failed to", g_tmp); }
			if (w == 0) { errno = EIO; close(tfd); close(sfd); die("write stalled on", g_tmp); }
			p += w; n -= w;
		}
	}
	if (n < 0) { close(tfd); close(sfd); die("read failed from", src); }
	(void)close(sfd);

	/* Force the group even without -g: a new temp can inherit the directory's
	 * group (a setgid directory, or BSD/macOS semantics), and the installed file
	 * must not keep the unprivileged user's group. uid may stay -1 (root, since
	 * we created the temp). */
	if (gid == (gid_t)-1) gid = getegid();
	if (fchown(tfd, uid, gid) != 0) { close(tfd); die("cannot set owner of", g_tmp); }
	if (mode >= 0 && fchmod(tfd, (mode_t)mode) != 0) { close(tfd); die("cannot set mode of", g_tmp); }
	if (fsync(tfd) != 0 && errno != EINVAL && errno != ENOTSUP) { close(tfd); die("fsync failed on", g_tmp); }

	/* A hardlink of the temp to DEST would make rename a successful no-op and
	 * leave the finished temp (with its final, maybe setuid, mode) behind for the
	 * that user to keep. Refuse a temp that is linked anywhere else, and capture
	 * its identity for the post-rename confirmation. */
	if (fstat(tfd, &fst) != 0) { close(tfd); die("cannot stat", g_tmp); }
	if (fst.st_nlink != 1) { close(tfd); errno = EPERM; die("temporary was linked elsewhere", g_tmp); }

	/* rename replaces whatever name is at DEST -- a file or a symlink -- in one
	 * step, acting on the name, never a symlink's target. Keep tfd open so the
	 * installed name can be confirmed to be the file just written (the directory's owner
	 * owning the directory could swap the temp name between the fchmod and the
	 * rename). */
	if (rename(g_tmp, dest) != 0) { close(tfd); die("cannot install", dest); }

	if (lstat(dest, &lst) != 0 || fst.st_dev != lst.st_dev || fst.st_ino != lst.st_ino ||
	    !S_ISREG(lst.st_mode) || lst.st_nlink != 1) {
		(void)unlink(dest);
		(void)unlink(g_tmp);
		g_have_tmp = 0;
		close(tfd);
		fprintf(stderr, "%s: %s changed under the install; removed\n", prog, dest);
		exit(1);
	}
	g_have_tmp = 0;
	(void)close(tfd);
}

static void usage(void)
{
	fprintf(stderr,
	    "usage: %s copy  -m MODE [-o OWNER] [-g GROUP] SRC DEST   install SRC as DEST\n"
	    "       %s mkdir [-m MODE] [-o OWNER] [-g GROUP] DIR      create DIR if absent, set owner/mode\n"
	    "       %s touch [-m MODE] [-o OWNER] [-g GROUP] NAME     create NAME if absent, set owner/mode\n"
	    "       %s set   [-m MODE] [-o OWNER] [-g GROUP] NAME     set owner/mode of an existing NAME\n",
	    prog, prog, prog, prog);
	exit(2);
}

static void install_signal_handlers(void)
{
	static const int sigs[] = { SIGINT, SIGTERM, SIGHUP, SIGQUIT, SIGPIPE, SIGALRM,
#ifdef SIGXFSZ
	    SIGXFSZ,	/* FreeBSD/NetBSD hide it under _POSIX_C_SOURCE; handle it where exposed */
#endif
	};
	struct sigaction sa, old;
	size_t i;
	memset(&sa, 0, sizeof sa);
	sa.sa_handler = on_signal;
	sigemptyset(&sa.sa_mask);
	for (i = 0; i < sizeof sigs / sizeof sigs[0]; i++) {
		if (sigaction(sigs[i], NULL, &old) == 0 && old.sa_handler != SIG_IGN)
			sigaction(sigs[i], &sa, NULL);	/* leave an inherited SIG_IGN (nohup) alone */
	}
}

int main(int argc, char **argv)
{
	enum { COPY, MKDIR, TOUCH, SET } action;
	const char *verb;
	int opt, nfd;
	long mode = -1;
	const char *owner = NULL, *group = NULL;
	uid_t uid;
	gid_t gid;

	/* Reserve fds 0-2 so a later open() cannot become stderr and have an error
	 * message write into an opened file. */
	do { nfd = open("/dev/null", O_RDWR); } while (nfd >= 0 && nfd < 3);
	if (nfd < 0) _exit(2);	/* could not reserve fds 0-2: refuse, so no later open becomes stderr */
	if (nfd >= 3) close(nfd);

	if (argc < 2) usage();
	verb = argv[1];
	if      (strcmp(verb, "copy")  == 0) action = COPY;
	else if (strcmp(verb, "mkdir") == 0) action = MKDIR;
	else if (strcmp(verb, "touch") == 0) action = TOUCH;
	else if (strcmp(verb, "set")   == 0) action = SET;
	else usage();
	argc--; argv++;			/* drop the verb; getopt the rest */

	while ((opt = getopt(argc, argv, "m:o:g:")) != -1) {
		switch (opt) {
		case 'm': mode = parse_octal(optarg); break;
		case 'o': owner = optarg; break;
		case 'g': group = optarg; break;
		default: usage();
		}
	}
	argc -= optind; argv += optind;

	if (action == COPY) {
		if (argc != 2) usage();
		if (mode < 0) { fprintf(stderr, "%s: copy needs -m MODE\n", prog); usage(); }
	} else {
		if (argc != 1) usage();
		if (mode >= 0 && (mode & 06000))
			{ fprintf(stderr, "%s: a setuid/setgid mode is only allowed with copy\n", prog); exit(2); }
	}

	install_signal_handlers();

	uid = lookup_user(owner);
	gid = lookup_group(group);

	/* A setuid/setgid file must end up root-owned. If it is given to the
	 * unprivileged user, that user owns the finished inode and can rewrite its
	 * content in the window before the final mode is set. -o unset keeps root,
	 * the temp's creator. */
	if (mode >= 0 && (mode & 06000)) {
		if (uid != 0 && !(uid == (uid_t)-1 && geteuid() == 0)) {
			fprintf(stderr, "%s: a setuid/setgid mode requires root ownership\n", prog);
			exit(2);
		}
		if (mode & 022) {	/* group- or world-writable: anyone there could rewrite the privileged file */
			fprintf(stderr, "%s: a setuid/setgid mode must not be group- or world-writable\n", prog);
			exit(2);
		}
	}

	if (action == COPY) {
		reject_bad_name(argv[1]);
		install_file(argv[0], argv[1], uid, gid, mode);
	} else if (action == TOUCH) {
		reject_bad_name(argv[0]);
		ensure_file(argv[0], uid, gid, mode);
	} else {
		reject_bad_name(argv[0]);
		if (action == MKDIR && mkdir(argv[0], 0700) != 0 && errno != EEXIST)
			die("cannot create directory", argv[0]);
		set_owner_and_mode(argv[0], uid, gid, mode, action == MKDIR);
	}
	return 0;
}
