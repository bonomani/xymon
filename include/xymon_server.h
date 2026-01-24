/*----------------------------------------------------------------------------*/
/* Xymon server-only header                                                   */
/*                                                                            */
/* This header groups all server-side dependencies that must NOT leak         */
/* into libxymon.h or client code.                                            */
/*                                                                            */
/*----------------------------------------------------------------------------*/

#ifndef __XYMON_SERVER_H__
#define __XYMON_SERVER_H__

/*
 * This header MUST only be included by server-side code.
 * It must never be included from libxymon.h or client code.
 */

#include "libxymon.h"

/* Server logging and HTML generation */
#include "../lib/eventlog.h"
#include "../lib/notifylog.h"
#include "../lib/htmllog.h"
#include "../lib/reportlog.h"
#include "../lib/acklog.h"
#include "../lib/acknowledgementslog.h"
#include "../lib/headfoot.h"

/* Server runtime and IPC */
#include "../lib/xymond_buffer.h"
#include "../lib/xymond_ipc.h"
#include "../lib/run.h"
#include "../lib/netservices.h"

/* Server configuration loaders */
#include "../lib/loadalerts.h"
#include "../lib/loadhosts.h"
#include "../lib/loadcriticalconf.h"

/*
 * IMPORTANT:
 * - No inline code
 * - No static variables
 * - No function definitions
 * - Includes only
 */

#endif /* __XYMON_SERVER_H__ */

