# keel-nodebb: NodeBB forum on nginx and Redis.
# Compatible with TurnKey Linux appliances: built with fab through the
# common tree, as a layer on top of the nodejs-nginx stack with bt-layer, or
# on its own with make.

COMMON_OVERLAYS += $(CURDIR)/overlay

include $(FAB_PATH)/common/mk/turnkey/nginx.mk
include $(FAB_PATH)/common/mk/turnkey.mk

# The project's own packages (inithooks, confconsole, keel) come from the
# build host's APT repository during the build only. The repository is copied
# into the bootstrap and listed as a [trusted=yes] file source, because the
# staging distribution is unsigned; conf.d/zz-project-packages checks what was
# installed against that copy, removes both from the image and leaves the
# future apt.keellinux.org entry in place, disabled.
KEEL_APT_REPO ?= /srv/keel-apt/repo
KEEL_APT_DIST ?= trixie-staging
KEEL_ARCHIVE_CHECK = $(CURDIR)/bin/keel-archive-check $(KEEL_APT_REPO)

# The copy is made fresh and then proved: bin/keel-archive-check compares the
# copied package index with the live one and stops the build when they differ.
define _keel_bootstrap/post

	mkdir -p $O/bootstrap/srv/keel-apt/repo;
	rm -rf $O/bootstrap/srv/keel-apt/repo/dists $O/bootstrap/srv/keel-apt/repo/pool;
	cp -a $(KEEL_APT_REPO)/dists $(KEEL_APT_REPO)/pool $O/bootstrap/srv/keel-apt/repo/;
	$(KEEL_ARCHIVE_CHECK) $O/bootstrap $(KEEL_APT_DIST) $(FAB_ARCH) bootstrap;
	echo "deb [trusted=yes] file:///srv/keel-apt/repo $(KEEL_APT_DIST) main" > $O/bootstrap/etc/apt/sources.list.d/keel-staging.list;
	fab-chroot $O/bootstrap "apt-get update";
endef
bootstrap/post += $(_keel_bootstrap/post)

# bootstrap is a stamped target, so a second build of the same product reuses
# the copy the first one made and a check in bootstrap/post does not run at
# all. On 2026-09-26 "make clean" failed on a busy deck, the stamps survived,
# and the rebuild installed the packages the archive had held that morning
# without a word. So the tree that is about to be configured is checked on
# every build, whether or not this build made the bootstrap.
define _keel_root.patched/pre

	$(KEEL_ARCHIVE_CHECK) $O/root.patched $(KEEL_APT_DIST) $(FAB_ARCH) root.patched;
endef
root.patched/pre += $(_keel_root.patched/pre)
