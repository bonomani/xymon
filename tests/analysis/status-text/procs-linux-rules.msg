@@client|1755640000|127.0.0.1|procs1.test|linux|linux|
[date]
Fri Oct 31 10:00:00 CET 2026
[ps]
  PID  PPID USER     STARTED S PRI %CPU     TIME %MEM   RSZ   VSZ CMD
    1     0 root     Oct30   S  80  0.0 00:00:03  0.1  9000 160000 /sbin/init
  912     1 xymon    Oct30   S  80  0.1 00:01:10  0.4 30000 400000 xymond --pidfile=/var/run/xymond.pid
  913   912 xymon    Oct30   S  80  0.0 00:00:01  0.2 12000 300000 xymond_channel --channel=status xymond_filestore
  914   912 xymon    Oct30   S  80  0.0 00:00:01  0.2 12000 300000 xymond_channel --channel=client xymond_client
  915   912 xymon    Oct30   S  80  0.0 00:00:01  0.2 12000 300000 xymond_channel --channel=data xymond_rrd
 2001     1 root     09:55   S  80  0.0 00:00:00  0.1  5000  80000 /usr/sbin/sshd -D
@@
