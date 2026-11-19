========
edpm-s2i
========

Element for building the edpm-hardened-uefi qcow2 image inside the
s2i-openstack-containers build appliance.

It provides what the ``centos``/``rhel`` distro elements and the
``repo-setup`` element provide for the upstream edpm-image-builder image
builds, without requiring network access:

* the distribution identity (``DISTRO_NAME``, ``DIB_RELEASE``, ``YUM``)
  and ``EFI_BOOT_DIR`` for the tarball based root filesystem
* the RPM repository collected in the ``os_source`` build stage as the
  only repository visible inside the chroot, restored again in the cleanup
  phase so the image keeps its upstream repository configuration
* distribution default ``dnf`` settings in the produced image instead of
  the container build overrides
* systemd unit enablement matching a deployed EDPM node instead of the
  container base image

The root filesystem itself comes from the ``tarball`` element, which
extracts the frozen ``os_source`` filesystem provided by Konflux.

Environment Variables
---------------------

``DIB_RELEASE``
    *Optional.* Release of the tarball content, defaults to
    ``10-stream``.

``DIB_EDPM_REPO_DIR``
    *Optional.* Location of the local RPM repository inside the chroot,
    defaults to ``/var/cache/edpm-repo``.
