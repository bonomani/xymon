	echo "Checking for IPv6 support ..."

	# Normally sourced by configure.server, which sets $MAKE. Default it so the
	# probe also works standalone (e.g. for debugging) -- an empty $MAKE would
	# otherwise run "-f Makefile.test-ipv6 ..." as a command, fail, and report a
	# false "No IPv6 support".
	PROBEMAKE="${MAKE:-make}"
	PROBEOS=`uname -s | sed -e's@/@_@g'`

	IPV6OK="YES"
	cd build
	OS="$PROBEOS" $PROBEMAKE -f Makefile.test-ipv6 clean >/dev/null 2>&1
	OS="$PROBEOS" $PROBEMAKE -f Makefile.test-ipv6 test-compile 2>/dev/null
	if test $? -eq 0; then
		echo "Compiling with IPv6 support works OK"
	else
		echo "No IPv6 support detected - building IPv4-only"
		IPV6OK="NO"
	fi
	OS="$PROBEOS" $PROBEMAKE -f Makefile.test-ipv6 clean >/dev/null 2>&1
	cd ..

	if test "$IPV6OK" = "YES"; then
		IPV6DEF="-DIPV4_SUPPORT -DIPV6_SUPPORT"
	else
		IPV6DEF="-DIPV4_SUPPORT"
	fi
