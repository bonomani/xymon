# Xymon solo mode — local health dashboard, on-demand UI

An overlay that runs Xymon as a **single-machine health monitor**: only the C
state engine runs continuously; the web dashboard is generated **on demand**.
No web server, no history, no RRD, no alerting, no network tests.

## What runs

| When | What | Cost |
|---|---|---|
| always | `xymonlaunch`, `xymond` (loopback only), `xymond_client` | idle C daemons |
| every 5 min | client collectors (`xymonclient.sh`) | ~1 s of shell |
| every 10 min | xymond checkpoint | one small file write |
| on demand | `xymon-dash` → `xymongen` → browser | ~100 ms |

## Install

1. Build and install Xymon server + client as usual.
2. Replace the placeholders and drop the files in:

   ```sh
   XH=/opt/xymon/server        # your server install dir
   XC=/opt/xymon/client        # your client install dir
   sed -e "s|@XYMONHOME@|$XH|g" -e "s|@XYMONCLIENTHOME@|$XC|g" tasks.cfg > $XH/etc/tasks.cfg
   cp hosts.cfg $XH/etc/hosts.cfg
   sed "s|@XYMONHOME@|$XH|g" xymon-dash > /usr/local/bin/xymon-dash && chmod +x /usr/local/bin/xymon-dash
   ```

3. Start `xymonlaunch`. On macOS, use the launchd job:

   ```sh
   sed "s|@XYMONHOME@|$XH|g" net.xymon.solo.plist > ~/Library/LaunchAgents/net.xymon.solo.plist
   launchctl load ~/Library/LaunchAgents/net.xymon.solo.plist
   ```

4. Open the dashboard whenever you want it:

   ```sh
   xymon-dash
   ```

## Optional: drill-down pages with lighttpd

The overview links each status to `svcstatus.cgi`, which needs CGI execution.
Without a web server those links are dead (use the CLI instead:
`xymoncmd xymon 127.0.0.1 "xymondlog localhost.cpu"`).

To enable them, install lighttpd (`brew install lighttpd`) and drop in the
provided config:

```sh
sed "s|@XYMONHOME@|$XH|g" lighttpd-solo.conf > $XH/etc/lighttpd-solo.conf
```

`xymon-dash` detects the file, starts lighttpd on first use (loopback only,
port 8080) and opens `http://127.0.0.1:8080/xymon/` instead of the static
file. Same `/xymon` + `/xymon-cgi` URL layout as the shipped Apache config,
so `xymonserver.cfg` needs no changes. The secured CGIs (enable/disable,
user admin) are not exposed.

## Notes
- **Graphs/history**: need `xymond_rrd`/`xymond_history` running continuously;
  add their standard `tasks.cfg` entries back if you want them and accept the
  extra disk writes.
- **Security**: `xymond` listens on 127.0.0.1 only; nothing is exposed on the
  network.
