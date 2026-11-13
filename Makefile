# keel-nodebb: NodeBB 4.16.7 behind Nginx on the LNPP stack of Keel
# (handbook note 0082), built as a layer on the lnpp layer:
#
#     bt-layer nodebb --parent lnpp
#
# Nginx, Coraza, Anubis and the default site come from the web layer;
# PostgreSQL 17, Python 3 and the pair of decision 0054 from the lnpp layer.
# Node.js is the Keel package keel-nodejs (note 0083). This layer adds
# NodeBB, its routes in keel-web's include directories, and the script that
# starts NodeBB on the node whose PostgreSQL accepts writes. Redis, the own
# Nginx site and the build time apt block of the old layer are gone.

COMMON_OVERLAYS += $(CURDIR)/overlay

# Webmin comes from core and answers on 12321; Nginx serves 80 and 443.
# NodeBB listens on the loopback, and PostgreSQL on a pair on the mesh only.
WEBMIN_FW_TCP_INCOMING = 22 80 443 12321

include $(FAB_PATH)/common/mk/turnkey.mk
