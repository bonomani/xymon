	echo "Checking for IPv6 support ..."

	IPV6OK="YES"
	cd build
	OS=`uname -s | sed -e's@/@_@g'` $MAKE -f Makefile.test-ipv6 clean >/dev/null 2>&1
	OS=`uname -s | sed -e's@/@_@g'` $MAKE -f Makefile.test-ipv6 test-compile 2>/dev/null
	if test $? -eq 0; then
		echo "Compiling with IPv6 support works OK"
	else
		echo "No IPv6 support detected - building IPv4-only"
		IPV6OK="NO"
	fi
	OS=`uname -s | sed -e's@/@_@g'` $MAKE -f Makefile.test-ipv6 clean >/dev/null 2>&1
	cd ..

	if test "$IPV6OK" = "YES"; then
		IPV6DEF="-DIPV4_SUPPORT -DIPV6_SUPPORT"
	else
		IPV6DEF="-DIPV4_SUPPORT"
	fi
