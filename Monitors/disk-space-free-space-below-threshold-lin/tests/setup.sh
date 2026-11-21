#!/bin/bash
# Test fixtures for the disk space monitor: real mounts in /proc/mounts (which
# the monitor reads directly) and shims first on the root PATH for the numbers.
#   /mnt/tc-ext4   loop-mounted ext4
#   /mnt/tc-btrfs  loop-mounted btrfs
#   /mnt/tc-fuse   type fuse.tcfake with no daemon behind it
# The shims read the run's input variables: tcTestUsedPct (df Use% for any
# /mnt/tc-* mount), tcTestBtrfsUnalloc (bytes btrfs reports unallocated; its
# metadata is always 90% used) and tcTestDfHang=1 (df never answers).
set -e
command -v mkfs.btrfs >/dev/null || { apt-get update -qq && apt-get install -y -qq btrfs-progs >/dev/null; }
mkdir -p /var/tmp/tc-disk /mnt/tc-ext4 /mnt/tc-btrfs /mnt/tc-fuse
truncate -s 64M /var/tmp/tc-disk/ext4.img
mkfs.ext4 -q -F /var/tmp/tc-disk/ext4.img
mount -o loop /var/tmp/tc-disk/ext4.img /mnt/tc-ext4
truncate -s 128M /var/tmp/tc-disk/btrfs.img
mkfs.btrfs -q -f /var/tmp/tc-disk/btrfs.img
mount -o loop /var/tmp/tc-disk/btrfs.img /mnt/tc-btrfs
# -i: no mount.fuse helper. fd 3 closes when this line ends, which aborts the
# connection (stat gives ENOTCONN, nothing hangs) but leaves the mount listed.
mount -i -t fuse.tcfake -o fd=3,rootmode=40000,user_id=0,group_id=0 tcfake /mnt/tc-fuse 3<>/dev/fuse
grep ' /mnt/tc-' /proc/mounts

realDf=$(command -v df)
realBtrfs=$(command -v btrfs)
test "$realDf" != /usr/local/sbin/df
cat >/usr/local/sbin/df <<SHIM
#!/bin/sh
# tc-test-shim: df for the disk space monitor's test; real df for anything else
for a; do last=\$a; done
case "\${last:-}" in
/mnt/tc-*)
	[ "\${tcTestDfHang:-}" = 1 ] && exec sleep 600
	pct=\${tcTestUsedPct:-50}
	echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'
	echo "tc-test 10485760 \$((pct * 104857)) 5242880 \${pct}% \$last"
	exit 0 ;;
esac
exec $realDf "\$@"
SHIM
cat >/usr/local/sbin/btrfs <<SHIM
#!/bin/sh
# tc-test-shim: btrfs filesystem usage for the disk space monitor's test
[ "\$1 \$2" = "filesystem usage" ] || exec $realBtrfs "\$@"
cat <<OUT
Overall:
    Device size:		   134217728
    Device unallocated:		  \${tcTestBtrfsUnalloc:-10737418240}

Data,single: Size:8388608, Used:0 (0.00%)
Metadata,DUP: Size:1073741824, Used:966367642 (90.00%)
System,DUP: Size:8388608, Used:16384 (0.20%)
OUT
SHIM
chmod 755 /usr/local/sbin/df /usr/local/sbin/btrfs
echo "shims installed"
