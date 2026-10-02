NodeBB - Forum for a project
============================

`NodeBB`_ is a forum platform built on Node.js: categories, topics with a
"solved" mode for support questions, discussion for everything that is not a
question, and ActivityPub for federation. This appliance is the project forum
of Keel Linux and the first appliance built the Keel way: as content addressed
layers on top of core, assembled into an LXC system container and first booted
from a declarative instance spec.

It is **compatible with TurnKey Linux appliances**: the recipe is a fab
product (``Makefile``, ``plan``, ``conf.d``, ``overlay``, ``changelog``) that
builds through the ``common`` tree, includes everything in `TurnKey Core`_, and
follows the conventions of the upstream ``nodejs`` and ``redis`` appliances.

Stack
-----

All from the Debian 13 (Trixie) archive except NodeBB itself:

- NodeBB 4.10.3, installed under ``/var/www/nodebb`` from the release
  tarball, pinned by version and sha256 in ``conf.d/main``. 4.10.3 is the last
  release whose pinned dependencies run on Node.js 20: 4.11.0 to 4.11.2 still
  declare ``node >= 20`` but pin ``undici 8.1.0``, which requires Node 22.19,
  and 4.11.3 and later declare ``node >= 22``. Trixie carries Node.js 20 only.
- Node.js 20.19 and npm from Debian.
- Redis 8.0 as the NodeBB database, bound to ``::1`` and ``127.0.0.1``.
- nginx in front on ``[::]:443`` and ``[::]:80`` (IPv6 first, IPv4 too),
  proxying to NodeBB on ``[::1]:4567``. The forum, ``forum.keellinux.org``,
  is served by a public services VM that terminates TLS and reverse proxies
  to the appliance over IPv6 on port 80: requests from the trusted
  proxy (``app.options.trusted_proxy``) with ``X-Forwarded-Proto: https`` are
  proxied, every other request on port 80 is redirected to https, and
  ``/.well-known/acme-challenge/`` stays served for http-01.
- A systemd unit, ``nodebb.service``, conditioned on ``config.json`` so it is
  inert until the first boot has run the setup.
- Postfix bound to localhost, Webmin, web shell, confconsole: TurnKey Core.

Layers
------

::

    core  ->  nodejs-nginx  ->  nodebb

``stacks/nodejs-nginx`` is the stack layer (nginx, Node.js, npm, Redis on
core); this directory is the appliance delta. Both are built with ``bt-layer``
from the organization's buildtasks and assembled with ``keel assemble``::

    cp -a stacks/nodejs-nginx $FAB_PATH/products/nodejs-nginx
    cp -a . $FAB_PATH/products/nodebb
    bt-layer nodejs-nginx --parent core
    bt-layer nodebb --parent nodejs-nginx

The recipe also builds on its own with ``make`` in a TKLDev, like any TurnKey
appliance.

The project's own packages (inithooks, confconsole, keel) are listed in the
plan and resolved, during the build only, from the build host's repository
copied into the bootstrap as a ``file:///srv/keel-apt/repo`` source
(``Makefile``, ``bootstrap/post``).

The build verifies that archive the way an appliance verifies the release one.
The public half of the staging key is installed into the build tree as
``/etc/apt/keyrings/keel-staging-keyring.asc``, the source entry names it
through ``signed-by``, and ``apt-get update`` runs with ``--error-on=any``, so
a signature that cannot be checked fails the build. It used to say
``[trusted=yes]``, which switches verification off: apt then printed
``W: OpenPGP signature verification failed ... Missing key`` and installed the
packages anyway (tracker#7).

That copy also has to be the archive as it is at build time: fab stamps the
bootstrap target, so a rebuild would otherwise reuse the copy an earlier build
made and install packages the archive no longer offers.
``bin/keel-archive-check`` compares the copied package index with the live one,
verifies the signature on the copied ``InRelease`` against that keyring,
refuses any ``trusted=yes`` anywhere in the tree, and does all of it twice:
where the copy is made, and again on the tree that is about to be configured.

``conf.d/zz-project-packages`` runs last. For each project package it checks
that the archive offers exactly one version, that apt's candidate is that
version, that the version comes from the project archive rather than an
upstream source, and that the installed package is that candidate and
configured. No version is written down anywhere, so a rebuild made after a
publication either carries the new versions or fails. It then removes the
build time source and the build-only pin ``conf.d/main`` gave it (the
staging Label at 1001, so it wins over TurnKey's 999 pin during the
upgrade), and fails if any apt file of the image still names that archive.
The appliance's own Keel source and its pin at 990 come from common
(``overlays/turnkey.d/keel-apt``); this recipe ships neither.

First boot
----------

The instance spec (``keel/instance.example.yaml``) is copied to
``/etc/keel/instance.yaml`` with the two secret files it names under
``/etc/keel/secrets``. ``keel spec apply`` renders it into the inithooks conf;
``firstboot.d/40nodebb`` reads ``APP_DOMAIN``, ``APP_EMAIL``, ``APP_PASS``,
``APP_ADMIN_USER`` and ``APP_TRUSTED_PROXY`` from it, writes the nginx
trusted proxy file, waits for Redis, runs ``./nodebb setup`` with a
JSON initial config (no dialog), binds NodeBB to ``[::1]:4567`` behind the
proxy and starts the service. The hook is idempotent: once ``config.json``
exists it does nothing. Decisions live in ``lib/nodebb.sh`` and are tested
with bats (``tests/nodebb.bats``); ``bin/nodebb.py`` holds the only dialog,
used when a value is absent and a terminal is attached.

Credentials
-----------

- Web shell, Webmin, SSH: ``root`` with the spec's ``root_password``.
- NodeBB admin: ``app.options.admin_user`` (default ``admin``) with the
  spec's ``app_password``.

Tests
-----

- ``tests/nodebb.bats`` and ``tests/coverage.sh``: the first boot library
  under bats and kcov.
- ``tests/boot-test.sh nodebb``: verify, pull and assemble the layers, adapt
  the rootfs for a container, boot it in LXC with a macvlan interface (global
  IPv6 by SLAAC), first boot from the spec, check nginx and the forum over
  IPv6 and ``keel diff`` against the spec.

License
-------

GPL-3.0-or-later (decision 0007). The recipe conventions come from
turnkeylinux-apps/nodejs and turnkeylinux-apps/redis, which declare no
license; this repository's own files are GPL-3.0-or-later.

.. _NodeBB: https://nodebb.org
.. _TurnKey Core: https://www.turnkeylinux.org/core
