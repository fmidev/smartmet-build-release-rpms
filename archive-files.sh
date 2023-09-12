#! /bin/sh

rhel=$(rpm --eval '%rhel')
if test -z "$rhel" ; then
    echo "No RHEL or derivative detected"
    exit 1
fi

dist=rhel$rhel

mkdir -p artifacts
timestamp=$(date +%Y%m%d_%H%M)
rpm_packages=$(cd workspace/export && find . -name '*.rpm' | sed -e 's:^\./::')
log_files=$(cd workspace/log && find . -type f | sed -e 's:^\./::')

if ! test -z "$rpm_packages" ; then
    cmd="tar cf artifacts/new-${dist}-release-rpms-${timestamp}.tar -C workspace/export $rpm_packages"
    echo "Execute: $cmd"
    $cmd
fi

if ! test -z "$log_files" ; then
    cmd="tar cJf artifacts/${dist}-build-logs-${timestamp}.tar.xz -C workspace/log $log_files"
    echo "Execute: $cmd"
    $cmd
fi

ls -l artifacts

