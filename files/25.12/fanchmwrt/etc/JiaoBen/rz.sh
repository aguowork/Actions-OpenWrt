#!/bin/sh

echo 1 >/proc/sys/oaf/test_mode
cat /proc/kmsg
