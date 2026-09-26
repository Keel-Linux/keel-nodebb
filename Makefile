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
# staging distribution is unsigned; conf.d/main removes both from the image
# and leaves the future apt.keellinux.org entry in place, disabled.
KEEL_APT_REPO ?= /srv/keel-apt/repo
KEEL_APT_DIST ?= trixie-staging

define _keel_bootstrap/post
	
	mkdir -p $O/bootstrap/srv/keel-apt/repo;
	cp -a $(KEEL_APT_REPO)/dists $(KEEL_APT_REPO)/pool $O/bootstrap/srv/keel-apt/repo/;
	echo "deb [trusted=yes] file:///srv/keel-apt/repo $(KEEL_APT_DIST) main" > $O/bootstrap/etc/apt/sources.list.d/keel-staging.list;
	fab-chroot $O/bootstrap "apt-get update";
endef
bootstrap/post += $(_keel_bootstrap/post)
