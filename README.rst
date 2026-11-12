NodeBB - Forum for a project
============================

`NodeBB`_ is a forum platform built on Node.js. This layer serves it behind
Nginx on the LNPP stack of Keel (handbook note 0082):

::

    core  ->  web  ->  lnpp  ->  nodebb

What the layer adds
-------------------

- NodeBB 4.16.7 in ``/var/www/nodebb``, from the release tarball at a
  pinned sha256, owned by root. The dependencies come from the reviewed
  lock file ``usr/share/keel-nodebb/package-lock.json`` with ``npm ci``.
- Node.js 24 from the Keel package ``keel-nodejs-24`` (note 0083). Each
  Node.js line is its own package, and the lines conflict. The layer names
  its line in ``plan/main``.
- ``nodebb-nodejs.path`` restarts NodeBB when ``/usr/lib/keel-nodejs/bin/node``
  changes. The Node.js package has no maintainer script, so without this
  unit NodeBB keeps the old binary after an upgrade.
- The session secret is in the one-row table ``keel_nodebb_secret`` of the
  database, so a pair shares it with the session rows. The first writable
  boot writes it (``secrets.nodebb_secret`` of the spec, which keel renders
  as ``KEEL_SECRET_NODEBB_SECRET``, else a new value), and no later boot
  changes it. ``serve.py`` gives it to NodeBB in the environment.
- PostgreSQL of lnpp in every mode: embedded in ``simple``, the pair of
  decision 0054 in the cloud modes. No Redis.
- ``nodebb.service`` runs ``usr/lib/keel-nodebb/serve.py`` as the user
  nodebb. It starts NodeBB only while PostgreSQL accepts writes, runs the
  schema upgrade before a start, and builds the assets again when the
  active plugins change. On a standby it writes ``/run/keel-nodebb/replica``,
  and Nginx shows the replica notice.
- The routes in ``/etc/nginx/keel-default.d/60-keel-nodebb.conf`` and
  ``keel-front.d``: NodeBB on ``127.0.0.1:4567``, socket.io with the
  Upgrade headers, a larger body on the upload routes only.
- The first boot hook ``45nodebb`` and ``bin/nodebb.py``: ``config.json``,
  the role and database ``nodebb`` (password ``secrets.db_password``), and
  ``./nodebb setup`` with the admin of the spec (``secrets.app_password``,
  ``app.options.admin_user``).
- NodeBB writes ``build/``, ``logs/``, the pidfile, the emoji data of
  nodebb-plugin-emoji, and ``/var/lib/nodebb/uploads``, which a pair
  replicates (``state.replicate`` of ``nodebb.yaml``).
- The check page of lnpp is removed.

Build
-----

The build needs ``keel-nodejs-24`` in the Keel archive that the build reads:

::

    bt-layer nodebb --parent lnpp

Open items
----------

- A login that survives a promote is not tested: no pair test ran. keel
  has no general path that gives one generated value to both nodes of a
  pair; this layer keeps its secret in the database instead.
- Coraza exclusions for posts are not written and not tested.
- The option ``trusted_proxy`` of the old layer is gone.
- No nodebb layer is published, so the `appliance` check fails until a
  layer on lnpp is published after commissioning.

Tests
-----

See ``COVERAGE.md`` and ``tests/README.md``.

.. _NodeBB: https://nodebb.org
