#!/bin/bash
# Shims first on the root PATH for the three time services the monitor asks.
# They read the run's input variables:
#   tcTestSource  chrony | ntp | timesyncd | none  (which service is "running")
#   tcTestOffset  the offset in that service's own format
#   tcTestSynced  yes | no  (timedatectl NTPSynchronized; chrony leap status)
#   tcTestHang=1  chronyc never answers
set -e
for t in chronyc ntpq timedatectl; do
	test "$(command -v $t || true)" != /usr/local/sbin/$t
done
real_tdc=$(command -v timedatectl || echo /bin/false)
cat >/usr/local/sbin/chronyc <<'SHIM'
#!/bin/sh
# tc-test-shim
[ "${tcTestHang:-}" = 1 ] && exec sleep 600
[ "${tcTestSource:-}" = chrony ] || { echo '506 Cannot talk to daemon'; exit 1; }
leap=Normal; [ "${tcTestSynced:-yes}" = no ] && leap='Not synchronised'
echo "C0000201,ntp.example.com,3,1700000000.123456789,${tcTestOffset:-0.000123},0.000045,0.000234,-12.345,0.001,0.050,0.012345678,0.001234567,1029.5,$leap"
SHIM
cat >/usr/local/sbin/ntpq <<'SHIM'
#!/bin/sh
# tc-test-shim
[ "${tcTestSource:-}" = ntp ] || { echo 'ntpq: read: Connection refused'; exit 1; }
leap=00; [ "${tcTestSynced:-yes}" = no ] && leap=11
echo "leap=$leap, offset=${tcTestOffset:-0.123}"
SHIM
cat >/usr/local/sbin/timedatectl <<SHIM
#!/bin/sh
# tc-test-shim
case "\$*" in
"show -p NTPSynchronized --value") echo "\${tcTestSynced:-yes}" ;;
timesync-status)
	[ "\${tcTestSource:-}" = timesyncd ] || { echo 'Failed to query server: Unit dbus-org.freedesktop.timesync1.service not found.' >&2; exit 1; }
	echo '       Server: 192.0.2.10 (ntp.example.com)'
	echo '         Leap: normal'
	echo "       Offset: \${tcTestOffset:--49.131ms}"
	echo '        Delay: 100.064ms' ;;
*) exec $real_tdc "\$@" ;;
esac
SHIM
chmod 755 /usr/local/sbin/chronyc /usr/local/sbin/ntpq /usr/local/sbin/timedatectl
echo "shims installed"
