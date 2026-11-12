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
- Node.js 24 from the Keel package ``keel-nodejs`` (note 0083).
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

The build needs ``keel-nodejs`` in the Keel archive that the build reads:

::

    bt-layer nodebb --parent lnpp

Open items
----------

- The secret ``nodebb_secret`` is in the manifest, but keel 0.23.96 renders
  only three secrets into the first boot. Until keel renders it, each node
  of a pair makes its own, and a login does not survive a promote.
- Coraza exclusions for posts are not written and not tested.
- The option ``trusted_proxy`` of the old layer is gone.
- The boot test still checks the published layer on nodejs-nginx.

Tests
-----

See ``COVERAGE.md`` and ``tests/README.md``.

.. _NodeBB: https://nodebb.org
