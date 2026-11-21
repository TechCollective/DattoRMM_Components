#!/bin/bash
# Undo setup.sh: shims, mounts (loop devices detach with them), images.
rm -f /usr/local/sbin/df /usr/local/sbin/btrfs
umount -l /mnt/tc-fuse /mnt/tc-ext4 /mnt/tc-btrfs
rm -rf /var/tmp/tc-disk
rmdir /mnt/tc-ext4 /mnt/tc-btrfs /mnt/tc-fuse
echo "test mounts left: $(grep -c ' /mnt/tc-' /proc/mounts)"
